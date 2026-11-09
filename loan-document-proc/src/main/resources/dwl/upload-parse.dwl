%dw 2.0
output application/java
/* Reads the upload request: folder (path), product (query) and the files of the multipart body.
   Only parts that have a filename are files; any client-side path is stripped. A request-level problem
   (bad folder, bad product, no files) is recorded in `problem` and answered 400 without touching the store. */
fun bin(c) = c match {
	case b is Binary -> b
	case s is String -> s as Binary { encoding: "UTF-8" }
	else -> write(c, "application/json") as Binary { encoding: "UTF-8" }
}
var parts = if (payload is Object) (payload.parts default {}) else {}
var files = (parts pluck ((value, key) -> {
	field: key as String,
	fileName: ((value.headers['Content-Disposition'].filename default '') splitBy /[\\/]/)[-1] default '',
	declaredMime: value.headers['Content-Type'] default (value.headers['content-type'] default ''),
	content: bin(value.content)
})) filter ((f) -> f.fileName != '')
var folder = attributes.uriParams.folder default ''
var product = attributes.queryParams.product default ''
var problem =
		if (not (folder matches /^[A-Za-z0-9_-]{3,64}$/)) { status: 400, code: "INVALID_FOLDER", message: "The folder name must be 3 to 64 letters, digits, underscores or hyphens." }
		else if (not (product matches /^[A-Z_]{2,30}$/)) { status: 400, code: "INVALID_PRODUCT", message: "The product query parameter is required (for example product=PL)." }
		else if (isEmpty(files)) { status: 400, code: "NO_FILES", message: "The request contains no files." }
		else null
---
{
	folder: folder,
	product: product,
	files: files,
	problem: problem,
	state: if (problem == null) "PENDING" else "PROBLEM"
}
