%dw 2.0
output application/json
---
{
	documents: vars.reconciliation.unexpected map ((f) -> {
		fileName: f.fileName,
		status: "UNEXPECTED",
		sizeBytes: f.size,
		sourcePath: f.key
	})
}
