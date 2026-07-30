class_name ReportCsv
extends Object
## Turns a ReportStore into the CSV file the tester sends to the team.

## The three columns the team asked for, plus the locale: five packs are in
## circulation and a report that does not say which one it is about cannot be
## acted on.
const HEADER: Array[String] = ["Locale", "Category", "Text", "User report"]

## RFC 4180 line ending, which is also what spreadsheets expect.
const LINE_ENDING: String = "\r\n"

## Byte order mark. Without it Excel on Windows reads the file as Latin-1 and
## mangles every accented word in the report, which is most of them.
const UTF8_BOM: Array[int] = [0xEF, 0xBB, 0xBF]


static func build(store: ReportStore) -> PackedByteArray:
	var lines: PackedStringArray = PackedStringArray(
			[_row(PackedStringArray(HEADER))])
	for row: PackedStringArray in store.rows():
		var full_row: PackedStringArray = PackedStringArray([store.locale])
		full_row.append_array(row)
		lines.append(_row(full_row))

	var bytes: PackedByteArray = PackedByteArray(UTF8_BOM)
	bytes.append_array((LINE_ENDING.join(lines) + LINE_ENDING).to_utf8_buffer())
	return bytes


## File name the tester downloads. Carries the locale and the pack version so
## several reports can sit side by side in an inbox.
static func file_name(store: ReportStore) -> String:
	var parts: PackedStringArray = PackedStringArray(["kalulu-report"])
	if not store.locale.is_empty():
		parts.append(store.locale)
	var stamp: String = _version_stamp(store.pack_version)
	if not stamp.is_empty():
		parts.append(stamp)
	return "_".join(parts) + ".csv"


static func _row(values: PackedStringArray) -> String:
	var escaped: PackedStringArray = PackedStringArray()
	for value: String in values:
		escaped.append(_escape(value))
	return ",".join(escaped)


static func _escape(value: String) -> String:
	# A leading =, +, - or @ makes a spreadsheet treat the cell as a formula.
	# Testers write free text, so prefix those with a quote to keep it text.
	var text: String = value
	if not text.is_empty() and text[0] in ["=", "+", "-", "@"]:
		text = "'" + text
	if text.contains("\"") or text.contains(",") or text.contains("\n") or text.contains("\r"):
		return "\"" + text.replace("\"", "\"\"") + "\""
	return text


## "2026-06-15T08:37:53" -> "2026-06-15". Keeps the file name readable.
static func _version_stamp(version: String) -> String:
	var trimmed: String = version.strip_edges()
	if trimmed.is_empty():
		return ""
	return trimmed.split("T")[0].replace("/", "-")
