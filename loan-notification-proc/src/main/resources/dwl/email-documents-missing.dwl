%dw 2.0
import * from modules::notice
output application/java
var app = vars.app
var detail = vars.incomplete default {}
var rules = vars.rules.rules
var base = p('mail.statusBaseUrl')
var missing = detail.missing default []
var missingFiles = detail.missingFiles default []
var quarantined = detail.quarantined default []
var duplicates = detail.duplicates default []
var mismatch = detail.mismatch
var checksumMismatches = (mismatch.checksumMismatches default [])
---
{
	subject: "Documents needed for your loan application $(app.applicationId)",
	body: ([
		"Dear $(app.applicantName),",
		"",
		"Thank you for applying for a $(productLabel(app.productCode)). Before we can assess application $(app.applicationId) we need the following:",
		""
	] ++ (if (detail.reason == "FOLDER_NOT_FOUND") [
		"- We could not find the upload folder named in your application, so we have not received any documents yet."
	] else []) ++ (missing map ((m) -> "- $(typeLabel(rules, m.docType)) ($(m.docType)): $(m.required) required, $(m.found) found"))
	  ++ (missingFiles map ((f) -> "- $(f.fileName) was listed in your application but we could not find it"))
	  ++ (quarantined map ((q) -> "- $(q.fileName) was not accepted: $(fileReason(q.reason))"))
	  ++ (duplicates map ((x) -> "- $(x.fileName) has the same content as another file you sent, so it counted only once"))
	  ++ (if (mismatch != null and mismatch.countMatches == false) [
		"- You declared $(mismatch.declaredCount) documents but we found $(mismatch.foundCount)"
	] else [])
	  ++ (checksumMismatches map ((c) -> "- $(c.fileName) does not match the checksum you declared"))
	  ++ [
		"",
		"How to send them:",
		"1. Put the missing or corrected files in the same upload folder you used before$(if (detail.folder != null) ' (' ++ detail.folder ++ ')' else '').",
		"2. Resubmit this application. You do not need to apply again: use $(base)/applications/$(app.applicationId)/resubmit.",
		"3. You can follow progress at $(base)/applications/$(app.applicationId)/status.",
		"",
		"Documents we have already accepted do not need to be sent again.",
		"",
		"Your reference: $(app.applicationId)"
	]) joinBy "\n"
}
