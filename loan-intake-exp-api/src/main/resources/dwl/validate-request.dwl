%dw 2.0
import try from dw::Runtime
output application/java

fun isBlank(s: String) = isEmpty(trim(s))
fun issue(field: String, message: String) = [{ field: field, message: message }]
fun missing(field: String) = issue(field, field ++ " is required")
fun isWhole(v) = (v mod 1) == 0

fun needText(field: String, v) =
	if (v == null) missing(field)
	else if ((v is String) and (isBlank(v) == false)) []
	else issue(field, field ++ " must be a non-empty text")

fun needRequestId(field: String, v) =
	if (v == null) missing(field)
	else if ((v is String) and (v matches /[A-Za-z0-9._-]{1,80}/)) []
	else issue(field, field ++ " must be 1 to 80 letters, digits, dots, dashes or underscores")

fun needPositive(field: String, v) =
	if (v == null) missing(field)
	else if ((v is Number) and (v > 0)) []
	else issue(field, field ++ " must be a number greater than 0")

fun needPositiveInt(field: String, v) =
	if (v == null) missing(field)
	else if ((v is Number) and (v > 0) and isWhole(v)) []
	else issue(field, field ++ " must be a whole number greater than 0")

fun needZeroOrMoreInt(field: String, v) =
	if (v == null) missing(field)
	else if ((v is Number) and (v >= 0) and isWhole(v)) []
	else issue(field, field ++ " must be a whole number, 0 or more")

fun optZeroOrMore(field: String, v) =
	if (v == null) []
	else if ((v is Number) and (v >= 0)) []
	else issue(field, field ++ " must be a number, 0 or more")

fun optZeroOrMoreInt(field: String, v) =
	if (v == null) []
	else if ((v is Number) and (v >= 0) and isWhole(v)) []
	else issue(field, field ++ " must be a whole number, 0 or more")

fun needIdentity(field: String, v) =
	if (v == null) missing(field)
	else if ((v is String) and (v matches /[A-Z]{5}[0-9]{4}[A-Z]/)) []
	else issue(field, field ++ " must be 5 capital letters, 4 digits and 1 capital letter")

fun needEmail(field: String, v) =
	if (v == null) missing(field)
	else if ((v is String) and (v matches /[^@\s]+@[^@\s]+\.[^@\s]+/)) []
	else issue(field, field ++ " must be a valid email address")

fun needBirthDate(field: String, v) =
	if (v == null) missing(field)
	else if ((v is String) == false) issue(field, field ++ " must be a date in yyyy-MM-dd format")
	else do {
		var parsed = try(() -> v as Date {format: "yyyy-MM-dd"})
		---
		if (parsed.success == false) issue(field, field ++ " must be a date in yyyy-MM-dd format")
		else if (parsed.result >= (now() as Date)) issue(field, field ++ " must be in the past")
		else []
	}

fun needFolder(field: String, v) =
	if (v == null) missing(field)
	else if ((v is String) and (v matches /[A-Za-z0-9][A-Za-z0-9._-]{0,99}/) and ((v contains "..") == false)) []
	else issue(field, field ++ " must be a simple folder name, without slashes, colons or '..'")

fun checkItems(items) =
	if (items == null) []
	else if ((items is Array) == false) issue("documents.documents", "documents.documents must be a list")
	else flatten(items map (item, i) -> do {
		var at = "documents.documents[" ++ (i as String) ++ "]"
		---
		needText(at ++ ".fileName", item.fileName)
		++ needText(at ++ ".type", item."type")
		++ (if ((item.sha256 == null) or ((item.sha256 is String) and (item.sha256 matches /[0-9a-fA-F]{64}/))) [] else issue(at ++ ".sha256", at ++ ".sha256 must be 64 hexadecimal characters"))
	})

var r = if (vars.request is Object) vars.request else {}
var a = if (r.applicant is Object) r.applicant else {}
var d = if (r.documents is Object) r.documents else {}
---
flatten([
	needRequestId("requestId", r.requestId),
	needText("productCode", r.productCode),
	needPositive("amount", r.amount),
	needPositiveInt("tenureMonths", r.tenureMonths),
	needText("applicant.fullName", a.fullName),
	needBirthDate("applicant.dateOfBirth", a.dateOfBirth),
	needIdentity("applicant.identityRef", a.identityRef),
	needEmail("applicant.email", a.email),
	needPositive("applicant.monthlyIncome", a.monthlyIncome),
	optZeroOrMore("applicant.monthlyObligations", a.monthlyObligations),
	optZeroOrMoreInt("applicant.employmentMonths", a.employmentMonths),
	needFolder("documents.folder", d.folder),
	needZeroOrMoreInt("documents.documentCount", d.documentCount),
	checkItems(d.documents)
])
