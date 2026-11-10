%dw 2.0
/*
  uploadChecks.dwl: the upload gate (checks run BEFORE anything is stored).

  Idea and first version: Member 3's Google Drive document app (upload-api / uploadChecks).
  Adapted here to the S3 store: files keep their own (validated) name, because the
  application manifest refers to files by name.

  If ANY file in the request fails, the whole request is rejected and nothing is stored.
  Checks, cheapest first, first failure wins:
    1  file name is safe (letters, digits, . _ -)         UNSUPPORTED_TYPE  (BAD_NAME)
    2  name starts with a document type of the product    UNSUPPORTED_TYPE  (NAME)
    3  not empty                                          EMPTY_OR_UNREADABLE
    4  size within the limit of that type                 FILE_TOO_LARGE
    5  extension allowed for that type                    UNSUPPORTED_TYPE  (EXTENSION)
    6  first bytes are PDF, JPEG or PNG (not a renamed
       text or program file)                              UNSUPPORTED_TYPE  (CONTENT)
    7  extension agrees with the content                  UNSUPPORTED_TYPE  (EXTENSION_CONTENT_MISMATCH)
    8  declared Content-Type agrees with the content      UNSUPPORTED_TYPE  (DECLARED_TYPE_MISMATCH)
    9  last bytes show the file is complete (not cut off) EMPTY_OR_UNREADABLE (TRUNCATED)
    10 same SHA-256 as an earlier file in this request    DUPLICATE_CONTENT
  The verification step (after the queue) still runs its own checks on whatever is in the bucket.

  Input file: { field, fileName, declaredMime, content (Binary) }
  Rule:       { docType, maxSizeBytes, allowedExtensions, ... }
*/
import toHex from dw::core::Binaries
import hashWith from dw::Crypto

var mimeByKind = { PDF: 'application/pdf', JPEG: 'image/jpeg', PNG: 'image/png' }
var declaredByKind = { PDF: ['application/pdf'], JPEG: ['image/jpeg', 'image/jpg'], PNG: ['image/png'] }
// Clients that do not know the type send these; they are not a mismatch.
var genericMimes = ['', 'application/octet-stream']

fun ext(name) = lower((name splitBy '.')[-1] default '')

fun kindOf(hex: String) =
  if (hex startsWith '255044462d') 'PDF'
  else if (hex startsWith 'ffd8ff') 'JPEG'
  else if (hex startsWith '89504e470d0a1a0a') 'PNG'
  else 'UNKNOWN'

fun extMatchesKind(e, kind) =
  (kind == 'PDF' and e == 'pdf')
  or (kind == 'JPEG' and (e == 'jpg' or e == 'jpeg'))
  or (kind == 'PNG' and e == 'png')

fun isComplete(kind, hex: String) = do {
  var tail = if (sizeOf(hex) > 2048) hex[-2048 to -1] else hex
  ---
  if (kind == 'PDF') (tail contains '2525454f46')
  else if (kind == 'PNG') (tail endsWith '49454e44ae426082')
  else (tail endsWith 'ffd9')
}

/* Document type from the file name: PAYSLIP_1.pdf -> PAYSLIP, id_proof.pdf -> ID_PROOF; null when nothing matches. */
fun typeOf(name, rules) = do {
  var stem = upper((name splitBy '.')[0] default '')
  var base = stem replace /_[0-9]+$/ with ''
  ---
  (rules filter ((r) -> do {
      var t = upper(r.docType)
      ---
      (stem startsWith t) or (base != '' and (t startsWith (base ++ '_')))
  }))[0].docType default null
}

fun mb(bytes) = ((bytes default 0) / 1048576) as String { format: "0.0" } ++ " MB"

fun fail(code, detail) = { reasonCode: code, detail: detail }

fun judge(f, rules) = do {
  var okName   = (f.fileName default '') matches /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/
  var docType  = if (okName) typeOf(f.fileName, rules) else null
  var rule     = (rules filter ((r) -> r.docType == docType))[0] default {}
  var size     = sizeOf(f.content)
  var e        = ext(f.fileName default '')
  var declared = trim(((lower(f.declaredMime default '')) splitBy ';')[0] default '')
  var base     = { field: f.field, file: f.fileName, docType: docType, size: size, content: f.content }
  ---
  if (not okName)                             base ++ fail('UNSUPPORTED_TYPE', 'BAD_NAME')
  else if (docType == null)                   base ++ fail('UNSUPPORTED_TYPE', 'NAME')
  else if (size == 0)                         base ++ fail('EMPTY_OR_UNREADABLE', 'EMPTY')
  else if (size > rule.maxSizeBytes)          base ++ fail('FILE_TOO_LARGE', 'TOO_LARGE')
  else if (not ((rule.allowedExtensions default []) contains e))
                                              base ++ fail('UNSUPPORTED_TYPE', 'EXTENSION')
  else do {
    var hex  = lower(toHex(f.content))
    var kind = kindOf(hex)
    var res  = base ++ { kind: kind, sha256: lower(toHex(hashWith(f.content, 'SHA-256'))) }
    ---
    if (kind == 'UNKNOWN')                    res ++ fail('UNSUPPORTED_TYPE', 'CONTENT')
    else if (not extMatchesKind(e, kind))     res ++ fail('UNSUPPORTED_TYPE', 'EXTENSION_CONTENT_MISMATCH')
    // `not` binds looser than `and` in DataWeave, so each negation is parenthesised.
    else if ((not (genericMimes contains declared)) and (not ((declaredByKind[kind] default []) contains declared)))
                                              res ++ fail('UNSUPPORTED_TYPE', 'DECLARED_TYPE_MISMATCH')
    else if (not isComplete(kind, hex))       res ++ fail('EMPTY_OR_UNREADABLE', 'TRUNCATED')
    else                                      res ++ { reasonCode: null, detail: null }
  }
}

/* Plain-language reason, safe to show to the applicant (no internal ids, paths or hashes). */
fun messageOf(r, rules) = do {
  var rule = (rules filter ((x) -> x.docType == r.docType))[0] default {}
  ---
  r.detail match {
    case 'BAD_NAME'  -> "The file name may only contain letters, digits, dots, underscores and hyphens, and must start with a letter or digit."
    case 'NAME'      -> "The file name does not match a document type. Start the name with one of: "
                        ++ ((rules map $.docType) joinBy ', ') ++ " (for example PAYSLIP_1.pdf)."
    case 'EMPTY'     -> "The file is empty (0 bytes)."
    case 'TOO_LARGE' -> "The file is " ++ mb(r.size) ++ ". The limit for " ++ r.docType ++ " is " ++ mb(rule.maxSizeBytes) ++ "."
    case 'EXTENSION' -> "Files ending in ." ++ ext(r.file default '') ++ " are not accepted for " ++ r.docType
                        ++ ". Allowed: " ++ ((rule.allowedExtensions default []) joinBy ', ') ++ "."
    case 'CONTENT'   -> "The file content is not a PDF, JPEG or PNG, whatever its extension says."
    case 'EXTENSION_CONTENT_MISMATCH' -> "The file extension does not match its content (the content is " ++ (r.kind default '') ++ ")."
    case 'DECLARED_TYPE_MISMATCH'     -> "The declared content type does not match the file content."
    case 'TRUNCATED' -> "The file looks cut short or damaged. Upload a complete copy."
    case 'DUPLICATE' -> "This file has the same content as another file in this upload."
    else -> "The document could not be accepted."
  }
}

/*
  checkBatch: runs judge on every file, then marks repeated content (the first copy is kept).
  Returns one result per file, in request order:
    field, file, docType, size, content, kind, sha256, mime, status ('OK' | 'REJECTED'), reasonCode, message
*/
fun checkBatch(files, rules) = do {
  var judged = (files reduce ((f, acc = { seen: [], out: [] }) -> do {
      var r   = judge(f, rules)
      var dup = r.reasonCode == null and (acc.seen contains r.sha256)
      var r2  = if (dup) (r -- ['reasonCode', 'detail']) ++ fail('DUPLICATE_CONTENT', 'DUPLICATE') else r
      ---
      { seen: if (r2.reasonCode == null) acc.seen ++ [r.sha256] else acc.seen,
        out:  acc.out ++ [r2] }
  })).out
  ---
  judged map ((r) -> r ++ {
    status:  if (r.reasonCode == null) 'OK' else 'REJECTED',
    mime:    mimeByKind[r.kind default ''] default 'application/octet-stream',
    message: if (r.reasonCode == null) null else messageOf(r, rules)
  })
}
