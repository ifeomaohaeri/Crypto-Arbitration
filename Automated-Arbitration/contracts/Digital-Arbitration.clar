;; Decentralized Arbitration System - A trustless dispute resolution platform
;; Enables secure escrow and neutral arbitration for digital agreements on Stacks blockchain

(define-constant ERR-UNAUTHORIZED-ACCESS (err u1001))
(define-constant ERR-INVALID-DISPUTE-PARAMETERS (err u1002))
(define-constant ERR-DISPUTE-NOT-FOUND (err u1003))
(define-constant ERR-ALREADY-RESOLVED (err u1004))
(define-constant ERR-INSUFFICIENT-BALANCE (err u1005))
(define-constant ERR-INVALID-STATUS-TRANSITION (err u1006))
(define-constant ERR-NO-RESOLUTION-PROVIDED (err u1007))
(define-constant ERR-DEADLINE-NOT-REACHED (err u1008))
(define-constant ERR-INVALID-ARBITRATOR (err u1009))
(define-constant ERR-PAYMENT-TRANSFER-FAILED (err u1010))
(define-constant ERR-INVALID-INPUT-PARAMETER (err u1011))
(define-constant ERR-EVIDENCE-SUBMISSION-LIMIT (err u1012))

(define-data-var platform-administrator principal tx-sender)
(define-data-var total-disputes-created uint u0)
(define-data-var arbitrator-service-fee uint u100)

(define-constant dispute-status-awaiting-acceptance u1)
(define-constant dispute-status-collecting-evidence u2)
(define-constant dispute-status-under-review u3)
(define-constant dispute-status-final-resolution u4)
(define-constant dispute-status-dispute-cancelled u5)

(define-constant arbitration-result-claimant-victory u1)
(define-constant arbitration-result-respondent-victory u2)
(define-constant arbitration-result-equal-distribution u3)

(define-map active-disputes
  uint
  {
    dispute-initiator: principal,
    dispute-defendant: principal,
    selected-arbitrator: principal,
    disputed-amount: uint,
    current-status: uint,
    final-arbitration-result: (optional uint),
    evidence-submission-deadline: uint,
    arbitration-decision-deadline: uint,
    dispute-summary: (string-ascii 256)
  }
)

(define-map submitted-evidence-records
  { case-identifier: uint, submitting-party: principal }
  (list 10 (string-ascii 64))
)

(define-public (configure-platform (new-administrator principal) (service-fee uint))
  (begin
    (asserts! (is-eq tx-sender (var-get platform-administrator)) ERR-UNAUTHORIZED-ACCESS)
    (asserts! (not (is-eq new-administrator 'SP000000000000000000002Q6VF78)) ERR-INVALID-INPUT-PARAMETER)
    (asserts! (and (>= service-fee u10) (<= service-fee u10000)) ERR-INVALID-INPUT-PARAMETER)
    (var-set platform-administrator new-administrator)
    (var-set arbitrator-service-fee service-fee)
    (ok true)
  )
)

(define-public (initiate-dispute-case 
  (opposing-party principal) 
  (chosen-arbitrator principal)
  (escrow-amount uint)
  (evidence-collection-period uint)
  (arbitration-review-period uint)
  (case-description (string-ascii 256))
)
  (let 
    (
      (new-dispute-id (+ (var-get total-disputes-created) u1))
      (total-required-payment (+ escrow-amount (var-get arbitrator-service-fee)))
      (current-blockchain-height block-height)
    )
    
    (asserts! (> escrow-amount u0) ERR-INSUFFICIENT-BALANCE)
    (asserts! (not (is-eq tx-sender opposing-party)) ERR-INVALID-DISPUTE-PARAMETERS)
    (asserts! (not (is-eq tx-sender chosen-arbitrator)) ERR-INVALID-ARBITRATOR)
    (asserts! (not (is-eq opposing-party chosen-arbitrator)) ERR-INVALID-ARBITRATOR)
    (asserts! (and (>= evidence-collection-period u10) (<= evidence-collection-period u10000)) ERR-INVALID-INPUT-PARAMETER)
    (asserts! (and (>= arbitration-review-period u10) (<= arbitration-review-period u10000)) ERR-INVALID-INPUT-PARAMETER)
    (asserts! (> (len case-description) u0) ERR-INVALID-INPUT-PARAMETER)
    
    (let
      (
        (evidence-cutoff-height (+ current-blockchain-height evidence-collection-period))
        (final-decision-deadline (+ evidence-cutoff-height arbitration-review-period))
      )
      
      (asserts! (is-ok (stx-transfer? total-required-payment tx-sender (as-contract tx-sender))) ERR-INSUFFICIENT-BALANCE)
      
      (map-set active-disputes new-dispute-id {
        dispute-initiator: tx-sender,
        dispute-defendant: opposing-party,
        selected-arbitrator: chosen-arbitrator,
        disputed-amount: escrow-amount,
        current-status: dispute-status-awaiting-acceptance,
        final-arbitration-result: none,
        evidence-submission-deadline: evidence-cutoff-height,
        arbitration-decision-deadline: final-decision-deadline,
        dispute-summary: case-description
      })
      
      (var-set total-disputes-created new-dispute-id)
      (ok new-dispute-id)
    )
  )
)

(define-public (accept-dispute-participation (case-identifier uint))
  (let 
    (
      (dispute-details (unwrap! (map-get? active-disputes case-identifier) ERR-DISPUTE-NOT-FOUND))
    )
    
    (asserts! (is-eq tx-sender (get dispute-defendant dispute-details)) ERR-UNAUTHORIZED-ACCESS)
    (asserts! (is-eq (get current-status dispute-details) dispute-status-awaiting-acceptance) ERR-INVALID-STATUS-TRANSITION)
    
    (asserts! (is-ok (stx-transfer? (var-get arbitrator-service-fee) tx-sender (as-contract tx-sender))) ERR-INSUFFICIENT-BALANCE)
    
    (map-set active-disputes case-identifier (merge dispute-details { current-status: dispute-status-collecting-evidence }))
    (ok true)
  )
)

(define-public (provide-case-evidence (case-identifier uint) (evidence-document-hash (string-ascii 64)))
  (let 
    (
      (dispute-details (unwrap! (map-get? active-disputes case-identifier) ERR-DISPUTE-NOT-FOUND))
    )
    
    (asserts! (or 
      (is-eq tx-sender (get dispute-initiator dispute-details)) 
      (is-eq tx-sender (get dispute-defendant dispute-details))
    ) ERR-UNAUTHORIZED-ACCESS)
    
    (asserts! (is-eq (get current-status dispute-details) dispute-status-collecting-evidence) ERR-INVALID-STATUS-TRANSITION)
    (asserts! (<= block-height (get evidence-submission-deadline dispute-details)) ERR-DEADLINE-NOT-REACHED)
    (asserts! (> (len evidence-document-hash) u0) ERR-INVALID-INPUT-PARAMETER)
    
    (let
      (
        (existing-evidence-list (default-to (list) (map-get? submitted-evidence-records { case-identifier: case-identifier, submitting-party: tx-sender })))
      )
      
      (asserts! (< (len existing-evidence-list) u10) ERR-EVIDENCE-SUBMISSION-LIMIT)
      
      (map-set submitted-evidence-records 
        { case-identifier: case-identifier, submitting-party: tx-sender } 
        (unwrap! (as-max-len? (append existing-evidence-list evidence-document-hash) u10) ERR-EVIDENCE-SUBMISSION-LIMIT)
      )
      (ok true)
    )
  )
)

(define-public (transition-to-arbitration-phase (case-identifier uint))
  (let 
    (
      (dispute-details (unwrap! (map-get? active-disputes case-identifier) ERR-DISPUTE-NOT-FOUND))
    )
    
    (asserts! (or 
      (> block-height (get evidence-submission-deadline dispute-details))
      (is-eq tx-sender (get selected-arbitrator dispute-details))
    ) ERR-DEADLINE-NOT-REACHED)
    
    (asserts! (is-eq (get current-status dispute-details) dispute-status-collecting-evidence) ERR-INVALID-STATUS-TRANSITION)
    
    (map-set active-disputes case-identifier (merge dispute-details { current-status: dispute-status-under-review }))
    (ok true)
  )
)

(define-public (render-final-judgment (case-identifier uint) (arbitration-verdict uint))
  (let 
    (
      (dispute-details (unwrap! (map-get? active-disputes case-identifier) ERR-DISPUTE-NOT-FOUND))
    )
    
    (asserts! (is-eq tx-sender (get selected-arbitrator dispute-details)) ERR-UNAUTHORIZED-ACCESS)
    (asserts! (is-eq (get current-status dispute-details) dispute-status-under-review) ERR-INVALID-STATUS-TRANSITION)
    (asserts! (or 
      (is-eq arbitration-verdict arbitration-result-claimant-victory)
      (is-eq arbitration-verdict arbitration-result-respondent-victory)
      (is-eq arbitration-verdict arbitration-result-equal-distribution)
    ) ERR-INVALID-STATUS-TRANSITION)
    
    (map-set active-disputes case-identifier (merge dispute-details { 
      current-status: dispute-status-final-resolution,
      final-arbitration-result: (some arbitration-verdict)
    }))
    
    (let
      (
        (case-initiator (get dispute-initiator dispute-details))
        (case-defendant (get dispute-defendant dispute-details))
        (total-disputed-funds (get disputed-amount dispute-details))
        (split-payment-amount (/ total-disputed-funds u2))
      )
      
      (if (is-eq arbitration-verdict arbitration-result-claimant-victory)
        (asserts! (is-ok (as-contract (stx-transfer? total-disputed-funds tx-sender case-initiator))) ERR-PAYMENT-TRANSFER-FAILED)
        (if (is-eq arbitration-verdict arbitration-result-respondent-victory)
          (asserts! (is-ok (as-contract (stx-transfer? total-disputed-funds tx-sender case-defendant))) ERR-PAYMENT-TRANSFER-FAILED)
          (begin
            (asserts! (is-ok (as-contract (stx-transfer? split-payment-amount tx-sender case-initiator))) ERR-PAYMENT-TRANSFER-FAILED)
            (asserts! (is-ok (as-contract (stx-transfer? split-payment-amount tx-sender case-defendant))) ERR-PAYMENT-TRANSFER-FAILED)
          )
        )
      )
      
      (asserts! (is-ok (as-contract (stx-transfer? (* (var-get arbitrator-service-fee) u2) tx-sender (get selected-arbitrator dispute-details)))) ERR-PAYMENT-TRANSFER-FAILED)
      (ok true)
    )
  )
)

(define-public (withdraw-dispute-case (case-identifier uint))
  (let 
    (
      (dispute-details (unwrap! (map-get? active-disputes case-identifier) ERR-DISPUTE-NOT-FOUND))
    )
    
    (asserts! (is-eq tx-sender (get dispute-initiator dispute-details)) ERR-UNAUTHORIZED-ACCESS)
    (asserts! (is-eq (get current-status dispute-details) dispute-status-awaiting-acceptance) ERR-INVALID-STATUS-TRANSITION)
    
    (map-set active-disputes case-identifier (merge dispute-details { current-status: dispute-status-dispute-cancelled }))
    
    (asserts! (is-ok (as-contract (stx-transfer? (+ (get disputed-amount dispute-details) (var-get arbitrator-service-fee)) tx-sender (get dispute-initiator dispute-details)))) ERR-PAYMENT-TRANSFER-FAILED)
    (ok true)
  )
)

(define-public (execute-timeout-resolution (case-identifier uint))
  (let 
    (
      (dispute-details (unwrap! (map-get? active-disputes case-identifier) ERR-DISPUTE-NOT-FOUND))
    )
    
    (asserts! (> block-height (get arbitration-decision-deadline dispute-details)) ERR-DEADLINE-NOT-REACHED)
    (asserts! (is-eq (get current-status dispute-details) dispute-status-under-review) ERR-INVALID-STATUS-TRANSITION)
    
    (map-set active-disputes case-identifier (merge dispute-details { 
      current-status: dispute-status-final-resolution,
      final-arbitration-result: (some arbitration-result-equal-distribution)
    }))
    
    (let 
      (
        (total-amount (get disputed-amount dispute-details))
        (equal-share (/ total-amount u2))
        (case-initiator (get dispute-initiator dispute-details))
        (case-defendant (get dispute-defendant dispute-details))
      )
      
      (asserts! (is-ok (as-contract (stx-transfer? equal-share tx-sender case-initiator))) ERR-PAYMENT-TRANSFER-FAILED)
      (asserts! (is-ok (as-contract (stx-transfer? equal-share tx-sender case-defendant))) ERR-PAYMENT-TRANSFER-FAILED)
      (asserts! (is-ok (as-contract (stx-transfer? (var-get arbitrator-service-fee) tx-sender case-initiator))) ERR-PAYMENT-TRANSFER-FAILED)
      (asserts! (is-ok (as-contract (stx-transfer? (var-get arbitrator-service-fee) tx-sender case-defendant))) ERR-PAYMENT-TRANSFER-FAILED)
      (ok true)
    )
  )
)

(define-read-only (retrieve-dispute-information (case-identifier uint))
  (map-get? active-disputes case-identifier)
)

(define-read-only (retrieve-submitted-evidence (case-identifier uint) (evidence-submitter principal))
  (map-get? submitted-evidence-records { case-identifier: case-identifier, submitting-party: evidence-submitter })
)

(define-read-only (get-current-arbitration-fee)
  (var-get arbitrator-service-fee)
)

(define-read-only (get-platform-administrator)
  (var-get platform-administrator)
)

(define-read-only (get-total-dispute-count)
  (var-get total-disputes-created)
)