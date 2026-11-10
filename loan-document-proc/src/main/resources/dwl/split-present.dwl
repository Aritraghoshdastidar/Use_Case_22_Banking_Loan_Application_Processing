%dw 2.0
output application/java
var accepted = (vars.app.documents default []) filter ((d) -> d.status == "ACCEPTED" and d.sha256 != null)
fun previous(f) = (accepted filter ((d) -> d.sourcePath == f.key and d.sizeBytes == f.size))[0]
var present = vars.reconciliation.present
---
{
	reused: (present filter ((f) -> previous(f) != null)) map ((f) -> {
		key: f.key,
		fileName: f.fileName,
		docType: f.docType,
		size: f.size,
		status: "ACCEPTED",
		reason: null,
		sha256: previous(f).sha256
	}),
	toValidate: present filter ((f) -> previous(f) == null)
}
