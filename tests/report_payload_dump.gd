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

	print("endpoint:      %s" % ReportSender.ENDPOINT)
	print("keys:          %s" % ", ".join(PackedStringArray(payload.keys())))
	print("locale:        %s" % payload.locale)
	print("flagged:       %d" % int(payload.flagged))
	print("csv bytes:     %d" % csv.size())
	print("name/email trimmed: %s / %s" % [payload.get("name"), payload.get("email")])
	print("wrote %s" % out_path)
	quit(0)
