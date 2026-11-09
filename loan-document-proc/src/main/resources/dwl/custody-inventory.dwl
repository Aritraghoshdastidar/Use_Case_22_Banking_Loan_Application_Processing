%dw 2.0
output application/json
---
{
	documents: vars.validation.accepted map ((r) -> {
		fileName: r.fileName,
		status: "ACCEPTED",
		sizeBytes: r.size,
		sourcePath: r.key,
		storedPath: p('store.verifiedPrefix') ++ vars.app.applicationId ++ "/" ++ r.fileName,
		(docType: r.docType) if r.docType != null,
		(sha256: r.sha256) if r.sha256 != null
	})
}
