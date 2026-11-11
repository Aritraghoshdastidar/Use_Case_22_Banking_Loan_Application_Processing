// What a customer may see (plain language, no scores or rule ids) and what is masked for everyone.

export const maskId = (s) => (s && s.length > 3 ? s.slice(0, 2) + '•'.repeat(s.length - 3) + s.slice(-1) : s || '');

const CUSTOMER_REASON = {
  SCORE_APPROVED: 'Your application met our lending criteria.',
  SCORE_NEEDS_REVIEW: 'Your application needs a specialist to look at it before we can decide.',
  SCORE_BELOW_THRESHOLD: 'Your overall assessment was below what we need for this loan.',
  AFFORDABILITY_REDUCED: 'The monthly instalment must stay within half of your income after existing payments, so we reduced the amount.',
  DATA_UNAVAILABLE: 'We could not read your credit information just now, so a specialist will review your application.',
  'HP-01': 'The loan would end after the maximum age we can lend to for this product.',
  'HP-02': 'Your credit record shows an unresolved default.',
  'HP-03': 'The instalment would be more than you can afford within our limit, and no smaller amount fits.',
};

export function plainReasons(codes) {
  return [...new Set((codes || []).map((c) => CUSTOMER_REASON[c]).filter(Boolean))];
}

/** The last "documents incomplete" event carries the exact list of what is needed. */
export function neededFrom(events) {
  const e = [...(events || [])].reverse().find((x) => x.event === 'DOCUMENTS_INCOMPLETE');
  if (!e || !e.detail) return null;
  const d = e.detail;
  return {
    reason: d.reason || null,
    missing: d.missing || [],
    missingFiles: d.missingFiles || [],
    quarantined: d.quarantined || [],
    duplicates: d.duplicates || [],
    manifest: d.manifest || null,
  };
}

/** Customer-safe view of an application: stage, files, decision in plain words, and the progress events. */
export function customerView(mapping, status, audit) {
  const events = ((audit && audit.events) || []).map((e) => ({ event: e.event, to: e.toStage, from: e.fromStage, at: e.createdAt, by: e.sourceApp }));
  const d = status && status.decision;
  return {
    applicationId: mapping.application_id,
    product: mapping.product,
    amount: mapping.amount,
    tenure: mapping.tenure,
    createdAt: mapping.created_at,
    stage: status ? status.stage : null,
    documents: status ? status.documents : [],
    needed: status && status.stage === 'DOCUMENTS_INCOMPLETE' ? neededFrom(audit && audit.events) : null,
    decision: d
      ? {
          outcome: d.decision,
          approvedAmount: d.approvedAmount,
          approvedTenure: d.approvedTenure,
          ratePct: d.approvedRatePct,
          instalment: d.instalment,
          offerExpiresAt: d.offerExpiresAt,
          reduced: !!d.reductionReason,
          reasons: plainReasons([...(d.reasonCodes || []), ...(d.reductionReason ? [d.reductionReason] : [])]),
        }
      : null,
    events,
  };
}

export function staffApplication(sys, audit, mapping) {
  const d = { ...sys };
  d.identityRef = maskId(d.identityRef);
  return { application: d, audit: (audit && audit.events) || [], owner: mapping ? { name: mapping.owner_name, email: mapping.owner_email } : null, needed: neededFrom(audit && audit.events) };
}

const UPLOAD_PRODUCT = /^[A-Z_]{2,30}$/;
const DRAFT = /^[a-z0-9]{6,20}$/;
export const validProduct = (p) => UPLOAD_PRODUCT.test(p || '');
export const validDraft = (d) => DRAFT.test(d || '');
