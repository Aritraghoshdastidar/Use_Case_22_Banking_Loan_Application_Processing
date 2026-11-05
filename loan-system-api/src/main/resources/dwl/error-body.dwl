%dw 2.0
output application/json
---
{
    code: vars.errorCode,
    // Business errors carry a safe, human message in error.description via raise-error.
    // Technical errors (DB, APIkit) get a generic message so no internal detail or submitted value leaks.
    message: if (vars.errorCode == "NOT_FOUND" or vars.errorCode == "CONFLICT" or vars.errorCode == "BAD_REQUEST")
                 (error.description default "Request could not be processed")
             else
                 "Request could not be processed",
    correlationId: correlationId
}
