%dw 2.0

fun money(n) = n as String {format: "#,##0.00"}
fun productLabel(code) = if (code == "HL") "home loan" else "personal loan"
fun plainDate(iso) = (iso as DateTime) as String {format: "d MMMM yyyy"}

// Why an application was declined, in plain language. Scores, thresholds and rule names are never shown.
fun declineSentence(code) = code match {
	case "HP-01" -> "The loan would still be running when you pass the maximum age up to which we lend."
	case "HP-02" -> "A default is recorded on one of your existing credit commitments."
	case "HP-03" -> "The monthly repayment would be too high compared with your income after your existing commitments."
	case "LOW_BUREAU_SCORE" -> "Your credit history shows a lower standing than we require."
	case "HIGH_DEBT_TO_INCOME" -> "Your existing commitments together with this loan would take too large a share of your income."
	case "HIGH_LOAN_TO_INCOME" -> "The amount you asked for is high compared with your yearly income."
	case "SHORT_EMPLOYMENT" -> "You have been in your current job for a short time."
	case "MISSED_PAYMENTS" -> "Payments on other credit were missed in the last two years."
	else -> "Overall, the application did not meet our lending criteria."
}
fun declineReasons(codes) = (codes map ((c) -> declineSentence(c))) distinctBy ((s) -> s)

// Why a document was not accepted, in plain language
fun fileReason(code) = code match {
	case "FILE_TOO_LARGE" -> "the file is larger than the size allowed for this document"
	case "UNSUPPORTED_TYPE" -> "the file is not an accepted type, or its content does not match its name"
	case "EMPTY_OR_UNREADABLE" -> "the file is empty, incomplete or could not be read"
	else -> "the file could not be accepted"
}

fun typeLabel(rules, docType) = ((rules default []) filter ((r) -> r.docType == docType))[0].description default docType

// How long an application has waited, in the largest sensible unit
fun unit(n, word) = "$(n) $(word)$(if (n == 1) '' else 's')"
fun waiting(minutes) = if (minutes < 60) unit(minutes, "minute")
	else if (minutes < 1440) unit(floor(minutes / 60), "hour")
	else unit(floor(minutes / 1440), "day")
