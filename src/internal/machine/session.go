// Package machine implements the voting machine orchestrator and session state machine.
//
// The session state machine enforces strict transition rules. Every state
// transition is validated against the transition table before executing.
// Invalid transitions are rejected and logged as anomalies.
package machine

import (
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/securevote/securevote/pkg/models"
)

// --- Errors ---

var (
	ErrInvalidTransition = errors.New("machine: invalid state transition")
	ErrSessionTimeout    = errors.New("machine: session timed out")
	ErrMaxSpoilsReached  = errors.New("machine: maximum spoil attempts reached")
	ErrPresenceLost      = errors.New("machine: voter presence lost")
	ErrMachineNotActive  = errors.New("machine: machine is not in ACTIVE_VOTING status")
)

// --- Configuration ---

// SessionConfig holds tunable parameters for the session state machine.
type SessionConfig struct {
	// Biometric thresholds
	BiometricAutoApproveThreshold float64       // Both models must exceed this (default 0.92)
	BiometricManualReviewThreshold float64      // Either model above this triggers manual review (default 0.80)

	// Timeouts
	IDScanTimeout          time.Duration // Default 30s
	BiometricTimeout       time.Duration // Default 15s
	ManualReviewTimeout    time.Duration // Default 5m
	TwoFactorTimeout       time.Duration // Default 2m
	BallotActiveTimeout    time.Duration // Default 15m
	BallotWarningBefore    time.Duration // Warning before timeout (default 3m)
	PausedTimeout          time.Duration // Default 60s
	VVPATReviewTimeout     time.Duration // Default 2m

	// Limits
	MaxSpoilAttempts       int           // Default 3

	// Presence monitoring
	PresenceLostThreshold  time.Duration // Default 10s
	PresenceCheckInterval  time.Duration // Default 500ms
}

// DefaultSessionConfig returns the default configuration.
func DefaultSessionConfig() SessionConfig {
	return SessionConfig{
		BiometricAutoApproveThreshold:  0.92,
		BiometricManualReviewThreshold: 0.80,
		IDScanTimeout:                  30 * time.Second,
		BiometricTimeout:               15 * time.Second,
		ManualReviewTimeout:            5 * time.Minute,
		TwoFactorTimeout:               2 * time.Minute,
		BallotActiveTimeout:            15 * time.Minute,
		BallotWarningBefore:            3 * time.Minute,
		PausedTimeout:                  60 * time.Second,
		VVPATReviewTimeout:             2 * time.Minute,
		MaxSpoilAttempts:               3,
		PresenceLostThreshold:          10 * time.Second,
		PresenceCheckInterval:          500 * time.Millisecond,
	}
}

// --- Transition Table ---

// transition defines a valid state transition with its required conditions.
type transition struct {
	From      models.SessionState
	To        models.SessionState
	Condition string // Human-readable description of the condition
}

// validTransitions is the canonical transition table.
// Any transition not in this table is rejected.
var validTransitions = []transition{
	{models.StateIdle, models.StateIDScanning, "ID inserted, machine is ACTIVE_VOTING"},
	{models.StateIDScanning, models.StateBiometricMatching, "ID valid and voter eligible"},
	{models.StateIDScanning, models.StateAuthFailed, "ID invalid, not found, expired, or stolen"},
	{models.StateBiometricMatching, models.StateTwoFactor, "Auto pass, 2FA enabled"},
	{models.StateBiometricMatching, models.StateTokenIssuance, "Auto pass, no 2FA"},
	{models.StateBiometricMatching, models.StateManualReview, "Either model uncertain"},
	{models.StateBiometricMatching, models.StateAuthFailed, "Both models reject"},
	{models.StateManualReview, models.StateTokenIssuance, "Worker approves"},
	{models.StateManualReview, models.StateAuthFailed, "Worker rejects"},
	{models.StateTwoFactor, models.StateTokenIssuance, "Code verified or fallback"},
	{models.StateTokenIssuance, models.StateBallotActive, "Token issued successfully"},
	{models.StateBallotActive, models.StateVVPATReview, "Voter confirms selections"},
	{models.StateBallotActive, models.StateSpoiled, "Voter requests spoil"},
	{models.StateBallotActive, models.StatePaused, "Presence lost"},
	{models.StatePaused, models.StateBallotActive, "Presence re-verified"},
	{models.StatePaused, models.StateSessionEnd, "Re-verification failed or timeout"},
	{models.StateSpoiled, models.StateBallotActive, "New ballot activated"},
	{models.StateVVPATReview, models.StateRecording, "Voter confirms paper"},
	{models.StateVVPATReview, models.StateSpoiled, "Voter rejects paper"},
	{models.StateRecording, models.StateReceipt, "Vote recorded successfully"},
	{models.StateReceipt, models.StateSessionEnd, "Receipt generated"},
	{models.StateAuthFailed, models.StateSessionEnd, "Help message shown"},

	// Timeout transitions (any state can timeout to SESSION_END)
	{models.StateIDScanning, models.StateSessionEnd, "Timeout"},
	{models.StateManualReview, models.StateSessionEnd, "Timeout"},
	{models.StateTwoFactor, models.StateSessionEnd, "Timeout or fallback failed"},
	{models.StateBallotActive, models.StateSessionEnd, "Timeout"},
	{models.StateVVPATReview, models.StateSessionEnd, "Timeout"},
}

// isValidTransition checks whether a state transition is in the transition table.
func isValidTransition(from, to models.SessionState) bool {
	for _, t := range validTransitions {
		if t.From == from && t.To == to {
			return true
		}
	}
	return false
}

// --- Session Implementation ---

// Session manages a single voter's interaction with the voting machine.
// It enforces the state machine, manages timeouts, and records all events.
type Session struct {
	mu sync.Mutex

	// Identity
	sessionID  string
	machineID  string
	precinctID string
	electionID string

	// State
	currentState   models.SessionState
	previousStates []stateEntry
	spoilCount     int

	// Timing
	startedAt       time.Time
	stateEnteredAt  time.Time
	timeoutTimer    *time.Timer

	// Data accumulated during the session
	idScanResult    *models.IDScanResult
	biometricResult *models.BiometricResult
	voter           *models.Voter
	blindToken      *models.BlindToken
	selections      []models.Selection
	voteCast        *models.VoteCast
	receipt         *models.Receipt

	// Presence monitoring
	presenceAlerts   int
	presencePauseSec int

	// Config
	config SessionConfig

	// Callbacks
	onStateChange func(from, to models.SessionState)
	onTimeout     func(state models.SessionState)
	onAnomaly     func(alert models.AnomalyAlert)

	// Logging
	events []SessionEvent
}

// stateEntry records a state and when it was entered.
type stateEntry struct {
	State     models.SessionState
	EnteredAt time.Time
	ExitedAt  time.Time
}

// SessionEvent is a structured log entry for everything that happens in a session.
type SessionEvent struct {
	Timestamp time.Time           `json:"timestamp"`
	EventType string              `json:"event_type"`
	State     models.SessionState `json:"state"`
	Details   map[string]string   `json:"details,omitempty"`
}

// NewSession creates a new voter session in the IDLE state.
func NewSession(sessionID, machineID, precinctID, electionID string, config SessionConfig) *Session {
	now := time.Now()
	return &Session{
		sessionID:    sessionID,
		machineID:    machineID,
		precinctID:   precinctID,
		electionID:   electionID,
		currentState: models.StateIdle,
		startedAt:    now,
		stateEnteredAt: now,
		config:       config,
		events:       make([]SessionEvent, 0, 50),
	}
}

// --- State Queries ---

// CurrentState returns the session's current state.
func (s *Session) CurrentState() models.SessionState {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.currentState
}

// SessionID returns the session's unique identifier.
func (s *Session) SessionID() string {
	return s.sessionID
}

// ElapsedTime returns how long the session has been active.
func (s *Session) ElapsedTime() time.Duration {
	return time.Since(s.startedAt)
}

// --- Internal State Transition ---

// transitionTo attempts a state transition. Returns an error if the transition is invalid.
func (s *Session) transitionTo(newState models.SessionState, details map[string]string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	oldState := s.currentState

	if !isValidTransition(oldState, newState) {
		// Log the invalid transition attempt as an anomaly
		s.logEvent("INVALID_TRANSITION_ATTEMPT", details)
		return fmt.Errorf("%w: %s -> %s", ErrInvalidTransition, oldState, newState)
	}

	now := time.Now()

	// Record the state we're leaving
	s.previousStates = append(s.previousStates, stateEntry{
		State:     oldState,
		EnteredAt: s.stateEnteredAt,
		ExitedAt:  now,
	})

	// Transition
	s.currentState = newState
	s.stateEnteredAt = now

	// Cancel any existing timeout
	if s.timeoutTimer != nil {
		s.timeoutTimer.Stop()
	}

	// Set new timeout for the new state
	s.setTimeoutForState(newState)

	// Log the transition
	if details == nil {
		details = make(map[string]string)
	}
	details["from"] = string(oldState)
	details["to"] = string(newState)
	s.logEvent("STATE_TRANSITION", details)

	// Fire callback (outside lock would be better, but simplified here)
	if s.onStateChange != nil {
		s.onStateChange(oldState, newState)
	}

	return nil
}

// setTimeoutForState configures the timeout timer for the given state.
func (s *Session) setTimeoutForState(state models.SessionState) {
	var timeout time.Duration

	switch state {
	case models.StateIDScanning:
		timeout = s.config.IDScanTimeout
	case models.StateBiometricMatching:
		timeout = s.config.BiometricTimeout
	case models.StateManualReview:
		timeout = s.config.ManualReviewTimeout
	case models.StateTwoFactor:
		timeout = s.config.TwoFactorTimeout
	case models.StateBallotActive:
		timeout = s.config.BallotActiveTimeout
	case models.StatePaused:
		timeout = s.config.PausedTimeout
	case models.StateVVPATReview:
		timeout = s.config.VVPATReviewTimeout
	default:
		return // No timeout for this state
	}

	s.timeoutTimer = time.AfterFunc(timeout, func() {
		s.handleTimeout(state)
	})
}

// handleTimeout is called when a state times out.
func (s *Session) handleTimeout(state models.SessionState) {
	if s.onTimeout != nil {
		s.onTimeout(state)
	}

	// Most timeouts transition to SESSION_END
	_ = s.transitionTo(models.StateSessionEnd, map[string]string{
		"reason": "timeout",
		"timed_out_state": string(state),
	})
}

// logEvent appends a structured event to the session log.
func (s *Session) logEvent(eventType string, details map[string]string) {
	s.events = append(s.events, SessionEvent{
		Timestamp: time.Now(),
		EventType: eventType,
		State:     s.currentState,
		Details:   details,
	})
}

// --- Public State Transition Methods ---

// BeginIDScan transitions from IDLE to ID_SCANNING.
func (s *Session) BeginIDScan() error {
	return s.transitionTo(models.StateIDScanning, nil)
}

// RecordIDScanResult stores the ID scan result and transitions based on eligibility.
func (s *Session) RecordIDScanResult(result *models.IDScanResult, voter *models.Voter, eligible *models.EligibilityResult) error {
	s.mu.Lock()
	s.idScanResult = result
	s.voter = voter
	s.mu.Unlock()

	if eligible == nil || !eligible.IsEligible {
		reason := "unknown"
		if eligible != nil {
			reason = eligible.Reason
		}
		return s.transitionTo(models.StateAuthFailed, map[string]string{
			"reason": reason,
		})
	}

	return s.transitionTo(models.StateBiometricMatching, nil)
}

// RecordBiometricResult stores the biometric result and transitions accordingly.
func (s *Session) RecordBiometricResult(result *models.BiometricResult, voterHas2FA bool) error {
	s.mu.Lock()
	s.biometricResult = result
	s.mu.Unlock()

	if result.Rejected {
		return s.transitionTo(models.StateAuthFailed, map[string]string{
			"reason":      "biometric_rejected",
			"confidence_a": fmt.Sprintf("%.4f", result.ModelAConfidence),
			"confidence_b": fmt.Sprintf("%.4f", result.ModelBConfidence),
		})
	}

	if result.RequiresManual {
		return s.transitionTo(models.StateManualReview, map[string]string{
			"confidence_a": fmt.Sprintf("%.4f", result.ModelAConfidence),
			"confidence_b": fmt.Sprintf("%.4f", result.ModelBConfidence),
		})
	}

	// Auto approved
	if voterHas2FA {
		return s.transitionTo(models.StateTwoFactor, nil)
	}
	return s.transitionTo(models.StateTokenIssuance, nil)
}

// RecordManualReview records a poll worker's manual identity verification.
func (s *Session) RecordManualReview(workerID string, approved bool) error {
	details := map[string]string{"worker_id": workerID}
	if approved {
		details["result"] = "approved"
		return s.transitionTo(models.StateTokenIssuance, details)
	}
	details["result"] = "rejected"
	return s.transitionTo(models.StateAuthFailed, details)
}

// RecordTwoFactorResult records 2FA verification outcome.
func (s *Session) RecordTwoFactorResult(verified bool) error {
	if verified {
		return s.transitionTo(models.StateTokenIssuance, map[string]string{
			"method": "two_factor",
		})
	}
	// 2FA failed — could fall back to manual or end
	return s.transitionTo(models.StateSessionEnd, map[string]string{
		"reason": "two_factor_failed",
	})
}

// RecordTokenIssued stores the blind token and activates the ballot.
func (s *Session) RecordTokenIssued(token *models.BlindToken) error {
	s.mu.Lock()
	s.blindToken = token
	s.mu.Unlock()

	return s.transitionTo(models.StateBallotActive, nil)
}

// RecordSelections stores the voter's current selections (can be updated until confirmed).
func (s *Session) RecordSelections(selections []models.Selection) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.selections = selections
	s.logEvent("SELECTIONS_UPDATED", map[string]string{
		"race_count": fmt.Sprintf("%d", len(selections)),
	})
}

// ConfirmSelections transitions to VVPAT review.
func (s *Session) ConfirmSelections() error {
	return s.transitionTo(models.StateVVPATReview, nil)
}

// ConfirmVVPAT transitions from VVPAT review to recording.
func (s *Session) ConfirmVVPAT() error {
	return s.transitionTo(models.StateRecording, map[string]string{
		"vvpat": "confirmed",
	})
}

// RejectVVPAT spoils the ballot when the paper doesn't match.
func (s *Session) RejectVVPAT() error {
	return s.SpoilBallot("voter_rejected_vvpat")
}

// SpoilBallot marks the current ballot as spoiled and starts a new one.
func (s *Session) SpoilBallot(reason string) error {
	s.mu.Lock()
	s.spoilCount++
	count := s.spoilCount
	s.mu.Unlock()

	if count > s.config.MaxSpoilAttempts {
		return ErrMaxSpoilsReached
	}

	err := s.transitionTo(models.StateSpoiled, map[string]string{
		"reason":      reason,
		"spoil_count": fmt.Sprintf("%d", count),
	})
	if err != nil {
		return err
	}

	// Immediately transition to a new BALLOT_ACTIVE state
	return s.transitionTo(models.StateBallotActive, map[string]string{
		"action": "new_ballot_after_spoil",
	})
}

// RecordVoteCast stores the completed VoteCast and transitions to receipt.
func (s *Session) RecordVoteCast(vc *models.VoteCast) error {
	s.mu.Lock()
	s.voteCast = vc
	s.mu.Unlock()

	return s.transitionTo(models.StateReceipt, nil)
}

// RecordReceipt stores the receipt and ends the session.
func (s *Session) RecordReceipt(receipt *models.Receipt) error {
	s.mu.Lock()
	s.receipt = receipt
	s.mu.Unlock()

	return s.transitionTo(models.StateSessionEnd, nil)
}

// PauseForPresenceLoss pauses the session when the voter's face is lost.
func (s *Session) PauseForPresenceLoss() error {
	s.mu.Lock()
	s.presenceAlerts++
	s.mu.Unlock()

	return s.transitionTo(models.StatePaused, map[string]string{
		"reason": "presence_lost",
	})
}

// ResumeAfterPresenceCheck resumes or ends based on re-verification.
func (s *Session) ResumeAfterPresenceCheck(verified bool) error {
	if verified {
		return s.transitionTo(models.StateBallotActive, map[string]string{
			"action": "resumed_after_presence_check",
		})
	}
	return s.transitionTo(models.StateSessionEnd, map[string]string{
		"reason": "presence_verification_failed",
	})
}

// EndSession forces the session to end (used for AUTH_FAILED flow).
func (s *Session) EndSession() error {
	return s.transitionTo(models.StateSessionEnd, nil)
}

// --- Callbacks ---

// OnStateChange registers a callback for state transitions.
func (s *Session) OnStateChange(cb func(from, to models.SessionState)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.onStateChange = cb
}

// OnTimeout registers a callback for state timeouts.
func (s *Session) OnTimeout(cb func(state models.SessionState)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.onTimeout = cb
}

// --- Session Summary ---

// Summary returns a MachineSession log record for this session.
func (s *Session) Summary() *models.MachineSession {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	duration := int(now.Sub(s.startedAt).Seconds())

	authResult := "ABORT"
	if s.biometricResult != nil {
		if s.biometricResult.AutoApproved {
			authResult = "AUTO_PASS"
		} else if s.biometricResult.RequiresManual {
			authResult = "MANUAL_PASS" // simplified; would check actual outcome
		}
	}

	summary := &models.MachineSession{
		SessionID:            s.sessionID,
		ElectionID:           s.electionID,
		MachineID:            s.machineID,
		PrecinctID:           s.precinctID,
		SessionStart:         s.startedAt,
		SessionEnd:           &now,
		DurationSec:          duration,
		AuthResult:           authResult,
		ManualReviewRequired: s.biometricResult != nil && s.biometricResult.RequiresManual,
		VoteCast:             s.voteCast != nil,
		WasSpoiled:           s.spoilCount > 0,
		SpoilCount:           s.spoilCount,
		PresenceAlerts:       s.presenceAlerts,
		PresencePauseSec:     s.presencePauseSec,
	}

	if s.biometricResult != nil {
		summary.BiometricConfidA = s.biometricResult.ModelAConfidence
		summary.BiometricConfidB = s.biometricResult.ModelBConfidence
	}

	if s.voteCast != nil {
		summary.VoteRecordID = s.voteCast.VoteRecordID
	}

	return summary
}

// Events returns the full session event log.
func (s *Session) Events() []SessionEvent {
	s.mu.Lock()
	defer s.mu.Unlock()
	events := make([]SessionEvent, len(s.events))
	copy(events, s.events)
	return events
}
