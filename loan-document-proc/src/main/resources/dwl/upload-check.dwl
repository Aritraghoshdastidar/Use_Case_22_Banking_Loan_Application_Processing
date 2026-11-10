%dw 2.0
output application/java
import checkBatch from dwl::uploadChecks
/* Runs the upload gate. Inputs: vars.upload (from upload-parse), vars.rules (checklist of the product, null when
   the system API does not know the product) and vars.existingNames (file names already in the folder).
   state: PROBLEM (request-level, nothing checked) | REJECTED (some file failed) | STAGED (all files may be stored). */
var rules = vars.rules.rules default []
var names = vars.upload.files map ((f) -> f.fileName)
var total = sizeOf((vars.existingNames ++ names) distinctBy ((n) -> n))
var maxFiles = Mule::p('verify.maxFiles') as Number
---
if (vars.rules == null)
	(vars.upload - "problem" - "state") ++ { state: "PROBLEM", problem: { status: 400, code: "UNKNOWN_PRODUCT", message: "There is no document checklist for this product." } }
else if (total > maxFiles)
	(vars.upload - "problem" - "state") ++ { state: "PROBLEM", problem: { status: 422, code: "TOO_MANY_FILES", message: "A folder can hold at most " ++ (maxFiles as String) ++ " files." } }
else do {
	var checked = checkBatch(vars.upload.files, rules)
	---
	(vars.upload - "state") ++ { checked: checked, state: if (isEmpty(checked filter ((c) -> c.status == "REJECTED"))) "STAGED" else "REJECTED" }
}
