%dw 2.0
output application/java
---
// Maps the request body to the named parameters of sql/create-application.sql.
// messageId becomes the outbox row id and the messageId inside the queue envelope.
{
    requestId: payload.requestId,
    payloadHash: payload.payloadHash,
    correlationId: payload.correlationId,
    productCode: payload.productCode,
    requestedAmount: payload.requestedAmount,
    requestedTenure: payload.requestedTenure,
    applicantName: payload.applicantName,
    dateOfBirth: payload.dateOfBirth as String,
    identityRef: payload.identityRef,
    email: payload.email,
    monthlyIncome: payload.monthlyIncome,
    monthlyObligations: payload.monthlyObligations default 0,
    employmentMonths: payload.employmentMonths default 0,
    manifest: write(payload.manifest, "application/json"),
    messageId: uuid(),
    createdAt: (now() >> "UTC") as String {format: "yyyy-MM-dd'T'HH:mm:ss'Z'"}
}
