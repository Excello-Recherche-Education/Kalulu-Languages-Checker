extends SceneTree
## Writes out the exact body ReportSender would POST, for the backend to check.
##
##   godot --headless --path . --script tests/report_payload_dump.gd -- <out.json>
##
## The checker and the endpoint that receives its reports live in different
## repositories and deploy separately, so nothing stops them disagreeing about a
## field name until a tester presses the button in production. This dumps a
## realistic payload; `tests/test_checker_report_contract.py` in Kalulu-Backend
## feeds it to the real handler and asserts it is accepted.
##
## Includes the awkward cases on purpose: accented text, an embedded comma and
## quote, and a comment long enough to be worth escaping properly.

func _initialize() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	var out_path: String = arguments[0] if arguments.size() > 0 else "payload.json"

	var store: ReportStore = ReportStore.new("fr_FR", "2026-08-31T07:26:00Z")
	store.set_comment("GP", "r-R", "the recording says something else")
	store.set_comment("Word", "café", "spelling is wrong, should be \"cafe\"")
	store.set_comment("Syllable", "chè", "much too quiet to hear")
	store.set_flagged("Sentence", "Mamá me ama.", true)

	var csv: PackedByteArray = ReportCsv.build(store)
	var payload: Dictionary = ReportSender.build_payload(
			store, csv, "  Jeanne Test  ", "  jeanne@example.org  ")

	var file: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write %s (%s)" % [
			out_path, error_string(FileAccess.get_open_error())])
		quit(1)
		return
	file.store_string(JSON.stringify(payload))
	file.close()

	# The stage name belongs in the path as well as the host, and getting that
	# wrong returns the gateway's own "Not Found" without ever reaching the
	# Lambda — which reads exactly like a route that was never deployed.
	_check("the default is the dev stage, and carries it in the path",
			ReportSender.endpoint_for("") == "https://dev.api.kalulu.org/dev/checker_report")
	_check("production is reachable on request, and carries its own stage",
			ReportSender.endpoint_for("prod") == "https://api.kalulu.org/prod/checker_report")
	# Reports are what testers wrote. A selector that could name an arbitrary
	# host would turn a crafted link into a way of collecting them.
	for hostile: String in ["https://evil.example.com/", "//evil.example.com",
			"PROD ", "dev", "anything"]:
		_check("\"%s\" cannot redirect the report" % hostile,
				ReportSender.endpoint_for(hostile) == "https://dev.api.kalulu.org/dev/checker_report")

	print("endpoint:      %s" % ReportSender.endpoint())
	print("keys:          %s" % ", ".join(PackedStringArray(payload.keys())))
	print("locale:        %s" % payload.locale)
	print("flagged:       %d" % int(payload.flagged))
	print("csv bytes:     %d" % csv.size())
	print("name/email trimmed: %s / %s" % [payload.get("name"), payload.get("email")])
	print("wrote %s" % out_path)
	quit(1 if _failures > 0 else 0)


var _failures: int = 0


func _check(what: String, passed: bool) -> void:
	print("  %s  %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
