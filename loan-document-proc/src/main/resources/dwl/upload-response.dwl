%dw 2.0
output application/json
/* The answer to an upload: 400/422 for a request problem, 422 listing every file when any is rejected, 201 when stored. */
var u = vars.upload
---
if (u.state == "PROBLEM") {
	code: u.problem.code,
	message: u.problem.message,
	correlationId: correlationId
}
else if (u.state == "REJECTED") {
	code: "DOCUMENT_VALIDATION_FAILED",
	message: "No files were stored. Fix the files marked REJECTED and upload the whole set again.",
	details: {
		folder: u.folder,
		rejected: sizeOf(u.checked filter ((c) -> c.status == "REJECTED")),
		files: u.checked map ((c) -> {
			field: c.field,
			file: c.file,
			docType: c.docType,
			status: c.status,
			reasonCode: c.reasonCode,
			message: c.message
		})
	},
	correlationId: correlationId
}
else {
	code: "FILES_STAGED",
	message: "All files passed the upload checks and were stored. Submit the application with this folder; verification runs when it is submitted.",
	details: {
		folder: u.folder,
		files: u.checked map ((c) -> {
			field: c.field,
			file: c.file,
			docType: c.docType,
			status: "STAGED"
		})
	},
	correlationId: correlationId
}
