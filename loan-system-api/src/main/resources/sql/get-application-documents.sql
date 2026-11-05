SELECT doc_type, file_name, status, reason, size_bytes, sha256, source_path, stored_path
FROM application_documents
WHERE application_id = :applicationId
ORDER BY id
