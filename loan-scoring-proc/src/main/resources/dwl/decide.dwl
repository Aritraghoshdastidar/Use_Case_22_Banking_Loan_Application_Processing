%dw 2.0
import * from modules::scoring
output application/json

var app = vars.app
var product = vars.product
var card = vars.scorecard
var bureau = vars.bureau
var today = vars.today as Date

var income = app.monthlyIncome
var obligations = app.monthlyObligations default 0
var net = income - obligations
var amount = app.requestedAmount
var tenure = app.requestedTenure
var rate = product.annualRatePct
var ceiling = product.emiCeilingPct / 100

// Affordability: indicative instalment against income net of obligations
var requestedEmi = emi(amount, rate, tenure)
var ratio = if (net > 0) round4(requestedEmi / net) else null
var withinCeiling = net > 0 and ratio <= ceiling
var reducedAmount = if (withinCeiling) amount
	else if (net > 0) maxAffordableAmount(net * ceiling, rate, tenure, product.amountStep)
	else 0
var reductionValid = !withinCeiling and reducedAmount >= product.minAmount

// Scorecard: one hit per factor with its value, weight, points and contribution
fun factorDef(name) = (card.factors filter ((f) -> f.factor == name))[0]
fun factorHit(name, value) = do {
	var f = factorDef(name)
	var pts = points(value, f.zeroPointsAt, f.fullPointsAt)
	---
	{
		ruleCode: name,
		ruleType: "FACTOR",
		inputValue: value,
		weight: f.weight,
		points: pts,
		contribution: contribution(f.weight, pts)
	}
}
var factorHits = if (bureau == null) [] else [
	factorHit("BUREAU_SCORE", bureau.bureauScore),
	factorHit("DEBT_TO_INCOME", round4((obligations + requestedEmi) / income)),
	factorHit("LOAN_TO_INCOME", round4(amount / (income * 12))),
	factorHit("EMPLOYMENT_STABILITY", app.employmentMonths),
	factorHit("REPAYMENT_HISTORY", bureau.missedPayments24m)
]
var score = round2(sum(factorHits map ((h) -> h.contribution)))

// Hard policy rules, each recorded whether or not it fired
var ageAtEnd = ageAtMaturity(app.dateOfBirth, today, tenure)
var hp01 = ageAtEnd > product.maxAgeAtMaturity
var hp02 = bureau != null and bureau.activeDefault == true
var hp03 = !withinCeiling and !reductionValid
var hardHits = if (bureau == null) [] else [
	{ ruleCode: "HP-01", ruleType: "HARD_RULE", inputValue: ageAtEnd, triggered: hp01 },
	{ ruleCode: "HP-02", ruleType: "HARD_RULE", inputValue: if (bureau.activeDefault == true) 1 else 0, triggered: hp02 },
	{ ruleCode: "HP-03", ruleType: "HARD_RULE", (inputValue: ratio) if ratio != null, triggered: hp03 }
]
var fired = hardHits filter ((h) -> h.triggered)

// Decision order: unreadable data first, then hard rules, then the score bands
var band = if (score >= card.approveMinScore) "APPROVED"
	else if (score >= card.referMinScore) "REFERRED"
	else "DECLINED"
var outcome = if (bureau == null) "REFERRED"
	else if (!isEmpty(fired)) "DECLINED"
	else band
var deciding = if (bureau == null) "DATA_UNAVAILABLE"
	else if (!isEmpty(fired)) fired[0].ruleCode
	else "BAND"

fun weakReason(code) = code match {
	case "BUREAU_SCORE" -> "LOW_BUREAU_SCORE"
	case "DEBT_TO_INCOME" -> "HIGH_DEBT_TO_INCOME"
	case "LOAN_TO_INCOME" -> "HIGH_LOAN_TO_INCOME"
	case "EMPLOYMENT_STABILITY" -> "SHORT_EMPLOYMENT"
	case "REPAYMENT_HISTORY" -> "MISSED_PAYMENTS"
	else -> code
}
var weak = (factorHits filter ((h) -> h.points < 50)) map ((h) -> weakReason(h.ruleCode))
var reasons = if (bureau == null) ["DATA_UNAVAILABLE"]
	else if (!isEmpty(fired)) (fired map ((h) -> h.ruleCode))
	else if (outcome == "APPROVED") (["SCORE_APPROVED"] ++ (if (withinCeiling) [] else ["AFFORDABILITY_REDUCED"]))
	else if (outcome == "REFERRED") ["SCORE_NEEDS_REVIEW"]
	else (["SCORE_BELOW_THRESHOLD"] ++ weak)

// Approved terms may differ from the request when the instalment would breach the ceiling
var approvedAmount = if (withinCeiling) amount else reducedAmount
---
{
	decision: outcome,
	(score: score) if bureau != null,
	scorecardVersion: card.version,
	decidingRule: deciding,
	reasonCodes: reasons,
	requestedAmount: amount,
	(affordabilityRatio: ratio) if (bureau != null and ratio != null),
	sourceApp: p('app.name'),
	correlationId: app.correlationId,
	ruleHits: if (bureau == null) [{ ruleCode: "DATA_UNAVAILABLE", ruleType: "HARD_RULE", triggered: true }]
		else (factorHits ++ hardHits)
} ++ (if (outcome == "APPROVED") {
	approvedAmount: approvedAmount,
	approvedTenure: tenure,
	approvedRatePct: rate,
	instalment: emi(approvedAmount, rate, tenure),
	(reductionReason: "AFFORDABILITY_REDUCED") if !withinCeiling,
	offerExpiresAt: (vars.nowUtc + ("P$(card.offerValidityDays)D" as Period)) as String {format: "yyyy-MM-dd'T'HH:mm:ss'Z'"}
} else {})
