%dw 2.0
import * from modules::notice
output application/java
var rows = vars.digestRows
---
{
	subject: "Underwriting digest: $(sizeOf(rows)) referred application$(if (sizeOf(rows) == 1) '' else 's') awaiting a decision",
	body: ([
		"The following applications have been referred and are waiting for an underwriting decision, oldest first.",
		""
	] ++ (rows map ((r) -> "- $(r.applicationId) | $(productLabel(r.productCode)) | requested $(money(r.requestedAmount)) | waiting $(waiting(r.ageMinutes))")) ++ [
		"",
		"Total: $(sizeOf(rows))"
	]) joinBy "\n"
}
