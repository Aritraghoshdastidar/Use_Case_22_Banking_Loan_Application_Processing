%dw 2.0
output application/json
fun toUtc(epoch) = if (epoch == null) null else epoch as DateTime {unit: "seconds"}
---
vars.rows map (row) -> {
	messageId: row.id,
	queue: row.queue_name,
	payload: read(row.payload, "application/json"),
	attempts: row.attempts,
	createdAt: toUtc(row.created_epoch)
}
