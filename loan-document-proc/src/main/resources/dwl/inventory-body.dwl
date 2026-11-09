%dw 2.0
output application/json
---
{
	documents: vars.validation.results map ((r) -> {
		fileName: r.fileName,
		status: r.status,
		sizeBytes: r.size,
		sourcePath: r.key,
		(docType: r.docType) if r.docType != null,
		(reason: r.reason) if r.reason != null,
		(sha256: r.sha256) if r.sha256 != null,
		(storedPath: p('store.quarantinePrefix') ++ vars.app.applicationId ++ "/" ++ r.fileName) if r.status == "QUARANTINED"
	})
}
