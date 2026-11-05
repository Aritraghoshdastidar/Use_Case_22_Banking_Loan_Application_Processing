%dw 2.0
output application/json
fun toUtc(epoch) = if (epoch == null) null else epoch as DateTime {unit: "seconds"}
---
{
	applicationId: vars.applicationId,
	events: vars.rows map (row) -> {
		id: row.id,
		event: row.event,
		fromStage: row.from_stage,
		toStage: row.to_stage,
		sourceApp: row.source_app,
		correlationId: row.correlation_id,
		detail: read(row.detail, "application/json"),
		createdAt: toUtc(row.created_epoch)
	}
}
