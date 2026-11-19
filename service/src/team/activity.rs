//! Participant activity (PROTOCOL.md 19.9).
//!
//! The service extracts one short line from what a participant is doing and
//! exposes it in `team.list`. Nothing here is persisted. Activity changes
//! alone announce themselves at most once per interval (2 s by default);
//! state changes keep the existing immediate `team.changed`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{now_ms, Participant, Role, TeamEvent, Teams};

/// Activity text is one line of at most 120 characters.
pub const MAX_ACTIVITY_CHARS: usize = 120;
/// Activity-only changes notify at most once per this many milliseconds.
pub const DEFAULT_NOTIFY_MS: u64 = 2_000;

/// `team.list`'s participant activity: the latest extracted line and when it
/// was observed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Activity {
    pub text: String,
    pub at: u64,
}

/// How long activity-only changes are coalesced before `team.changed`.
pub fn notify_interval_ms() -> u64 {
    std::env::var("NVIM_ADE_SERVER_ACTIVITY_NOTIFY_MS")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .unwrap_or(DEFAULT_NOTIFY_MS)
}

/// The 2-second notification gate of one participant.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ActivityThrottle {
    /// When activity was last sent in a `team.changed`.
    last_sent: Option<u64>,
    /// When the pending activity change must be sent.
    due_at: Option<u64>,
}

impl ActivityThrottle {
    /// Record an activity change. Returns true when it may be announced now;
    /// otherwise the last value stays pending until [`Self::is_due`].
    pub fn record(&mut self, now: u64, interval: u64) -> bool {
        match self.last_sent {
            Some(last) if now.saturating_sub(last) < interval => {
                self.due_at = Some(last.saturating_add(interval));
                false
            }
            _ => {
                self.last_sent = Some(now);
                self.due_at = None;
                true
            }
        }
    }

    /// Whether a throttled change is waiting for its window.
    pub fn is_due(&self, now: u64) -> bool {
        self.due_at.is_some_and(|at| at <= now)
    }

    /// The current activity was just delivered by some other `team.changed`.
    pub fn flushed(&mut self, now: u64) {
        self.last_sent = Some(now);
        self.due_at = None;
    }

    #[cfg(test)]
    fn pending(&self) -> Option<u64> {
        self.due_at
    }
}

impl Participant {
    pub fn set_state(&mut self, state: super::ParticipantState) {
        if self.state != state {
            self.state = state;
            self.state_since = now_ms();
            // The state-change `team.changed` already carries the current
            // activity, so a throttled activity notice would be redundant.
            self.activity_throttle.flushed(self.state_since);
        }
    }

    /// Store one activity line and say whether it should be announced now.
    pub fn observe_activity(&mut self, text: String, now: u64, interval: u64) -> bool {
        let text = clip(&text);
        if text.is_empty() {
            return false;
        }
        if self
            .activity
            .as_ref()
            .is_some_and(|activity| activity.text == text)
        {
            // The source was seen (so the end-of-turn fallback does not apply),
            // but unchanged text neither moves `at` nor reopens the throttle.
            self.turn_activity = true;
            return false;
        }
        self.activity = Some(Activity { text, at: now });
        self.turn_activity = true;
        self.activity_throttle.record(now, interval)
    }

    /// End-of-turn fallback for workers: when no source produced activity
    /// during the bus turn, the first line of the turn text does. The turn-end
    /// `team.changed` carries it, so the throttle is marked as delivered.
    pub fn finish_turn_activity(&mut self, text: &str, bus_turn: bool, now: u64) {
        if self.role == Role::Worker && bus_turn && !self.turn_activity {
            let line = clip(text);
            if !line.is_empty() {
                self.activity = Some(Activity {
                    text: line,
                    at: now,
                });
            }
        }
        self.turn_activity = false;
        self.activity_throttle.flushed(now);
    }
}

/// The first line of `text`, trimmed.
pub fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or("").trim().to_string()
}

/// One line, at most [`MAX_ACTIVITY_CHARS`] characters.
pub fn clip(text: &str) -> String {
    let line = first_line(text);
    line.chars().take(MAX_ACTIVITY_CHARS).collect()
}

/// The activity from one `session/update`, if it is one of the worker sources
/// (19.9). Leaders only get activity from their `bus.*` calls.
pub fn from_update(update: &Value, role: Role) -> Option<String> {
    if role != Role::Worker {
        return None;
    }
    let kind = update.get("sessionUpdate").and_then(Value::as_str)?;
    match kind {
        "tool_call" | "tool_call_update" => {
            let title = update.get("title").and_then(Value::as_str)?;
            let text = if update.get("status").and_then(Value::as_str) == Some("failed") {
                format!("failed: {title}")
            } else {
                title.to_string()
            };
            Some(clip(&text))
        }
        "plan" => {
            let entries = update
                .get("entries")
                .or_else(|| update.get("plan"))
                .and_then(Value::as_array)?;
            entries
                .iter()
                .find(|entry| entry.get("status").and_then(Value::as_str) == Some("in_progress"))
                .and_then(|entry| entry.get("content").and_then(Value::as_str))
                .map(clip)
        }
        _ => None,
    }
}

/// The activity of one successful `bus.*` call (19.9).
pub fn from_bus(method: &str, params: &Value, result: &Value) -> Option<String> {
    let text = match method {
        "bus.send" => {
            let to = params.get("to").and_then(Value::as_str).unwrap_or("?");
            let kind = params
                .get("kind")
                .and_then(Value::as_str)
                .unwrap_or("message");
            let task = params
                .get("task")
                .and_then(Value::as_str)
                .filter(|task| *task != "_" && !task.is_empty());
            let suffix = task.map(|task| format!(" {task}")).unwrap_or_default();
            let body = params.get("body").and_then(Value::as_str).unwrap_or("");
            format!("→ {to} {kind}{suffix}: {}", first_line(body))
        }
        "bus.ask_human" => {
            let question = params.get("question").and_then(Value::as_str).unwrap_or("");
            format!("asks: {}", first_line(question))
        }
        "bus.spawn" => {
            // The service-assigned name wins: a worktree spawn with no explicit
            // name gets one after the request was created.
            let name = result
                .get("name")
                .and_then(Value::as_str)
                .or_else(|| params.get("name").and_then(Value::as_str))
                .or_else(|| params.get("template").and_then(Value::as_str))
                .unwrap_or("?");
            format!("spawn {name}")
        }
        "bus.card_update" => {
            let card = params.get("card").and_then(Value::as_str).unwrap_or("?");
            format!("card {card} updated")
        }
        "bus.board_update" => "board updated".to_string(),
        "bus.workflow_save" => {
            let name = params
                .get("workflow")
                .and_then(|workflow| workflow.get("name"))
                .and_then(Value::as_str)
                .unwrap_or("?");
            format!("workflow {name} saved")
        }
        "bus.workflow_get" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("?");
            format!("workflow {name} read")
        }
        "bus.workflow_delete" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("?");
            format!("workflow {name} deleted")
        }
        _ => return None,
    };
    Some(clip(&text))
}

impl Teams {
    /// Feed one `session/update` to the actor's activity. Only workers have
    /// non-bus activity sources.
    pub fn observe_activity_update(
        &mut self,
        instance: &str,
        session: Option<&str>,
        update: &Value,
        now: u64,
    ) -> bool {
        let Some(team) = self.teams.values().find(|team| {
            team.is_worker_instance(instance).is_some() || team.is_leader_instance(instance)
        }) else {
            return false;
        };
        let team_id = team.id.clone();
        let name = if let Some(name) = team.is_worker_instance(instance) {
            name.to_string()
        } else {
            "leader".to_string()
        };
        let Some(participant) = self
            .teams
            .get_mut(&team_id)
            .and_then(|team| team.participants.get_mut(&name))
        else {
            return false;
        };
        if session.is_some_and(|session| participant.session.as_deref() != Some(session)) {
            return false;
        }
        let role = participant.role;
        let Some(text) = from_update(update, role) else {
            return false;
        };
        let notify = participant.observe_activity(text, now, notify_interval_ms());
        if notify {
            self.events.push(TeamEvent::Changed(team_id));
        }
        notify
    }

    /// Record one successful participant `bus.*` call. Leaders get activity
    /// only from here.
    pub fn note_bus_call(
        &mut self,
        team_id: &str,
        name: &str,
        method: &str,
        params: &Value,
        result: &Value,
        now: u64,
    ) -> bool {
        let Some(text) = from_bus(method, params, result) else {
            return false;
        };
        let Some(participant) = self
            .teams
            .get_mut(team_id)
            .and_then(|team| team.participants.get_mut(name))
        else {
            return false;
        };
        let notify = participant.observe_activity(text, now, notify_interval_ms());
        if notify {
            self.events.push(TeamEvent::Changed(team_id.to_string()));
        }
        notify
    }

    /// Announce activity changes whose throttle window ended.
    pub fn flush_due_activities(&mut self, now: u64) {
        let mut changed = Vec::new();
        for (id, team) in self.teams.iter_mut() {
            let mut due = false;
            for participant in team.participants.values_mut() {
                if participant.activity_throttle.is_due(now) {
                    participant.activity_throttle.flushed(now);
                    due = true;
                }
            }
            if due {
                changed.push(id.clone());
            }
        }
        for id in changed {
            self.events.push(TeamEvent::Changed(id));
        }
    }

    /// Test helper: the activity of one participant.
    #[cfg(test)]
    pub fn activity_of(&self, team_id: &str, name: &str) -> Option<Activity> {
        self.teams
            .get(team_id)?
            .participants
            .get(name)?
            .activity
            .clone()
    }

    #[cfg(test)]
    pub fn state_since_of(&self, team_id: &str, name: &str) -> Option<u64> {
        self.teams
            .get(team_id)?
            .participants
            .get(name)
            .map(|participant| participant.state_since)
    }

    #[cfg(test)]
    pub fn participant_mut_for_test(
        &mut self,
        team_id: &str,
        name: &str,
    ) -> Option<&mut Participant> {
        self.teams.get_mut(team_id)?.participants.get_mut(name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn tool_call_titles_and_failed_status() {
        let update = json!({
            "sessionUpdate": "tool_call",
            "title": "Run cargo test",
            "status": "in_progress",
        });
        assert_eq!(
            from_update(&update, Role::Worker).as_deref(),
            Some("Run cargo test")
        );
        let failed = json!({
            "sessionUpdate": "tool_call_update",
            "title": "Edit hub.rs",
            "status": "failed",
        });
        assert_eq!(
            from_update(&failed, Role::Worker).as_deref(),
            Some("failed: Edit hub.rs")
        );
        let untitled = json!({"sessionUpdate": "tool_call_update", "status": "completed"});
        assert_eq!(from_update(&untitled, Role::Worker), None);
    }

    #[test]
    fn plans_use_the_in_progress_entry() {
        let update = json!({
            "sessionUpdate": "plan",
            "entries": [
                {"content": "done step", "status": "completed"},
                {"content": "补 reconnect 的回归测试", "status": "in_progress"},
                {"content": "later", "status": "pending"}
            ]
        });
        assert_eq!(
            from_update(&update, Role::Worker).as_deref(),
            Some("补 reconnect 的回归测试")
        );
        let none = json!({
            "sessionUpdate": "plan",
            "entries": [{"content": "x", "status": "pending"}]
        });
        assert_eq!(from_update(&none, Role::Worker), None);
    }

    #[test]
    fn leaders_only_use_bus_calls() {
        let update = json!({
            "sessionUpdate": "tool_call",
            "title": "spawn things",
            "status": "in_progress",
        });
        assert_eq!(from_update(&update, Role::Leader), None);
        assert_eq!(
            from_bus(
                "bus.send",
                &json!({"to": "w1", "kind": "task", "task": "T4", "body": "do it\nmore"}),
                &json!({})
            )
            .as_deref(),
            Some("→ w1 task T4: do it")
        );
        assert_eq!(
            from_bus("bus.board_update", &json!({}), &json!({"rev": 3})).as_deref(),
            Some("board updated")
        );
    }

    #[test]
    fn bus_calls_have_short_descriptions() {
        assert_eq!(
            from_bus(
                "bus.send",
                &json!({"to": "leader", "kind": "report", "task": "T4",
                         "body": "tests pass\nand more"}),
                &json!({})
            )
            .as_deref(),
            Some("→ leader report T4: tests pass")
        );
        assert_eq!(
            from_bus(
                "bus.send",
                &json!({"to": "leader", "kind": "report", "body": "plain"}),
                &json!({})
            )
            .as_deref(),
            Some("→ leader report: plain")
        );
        assert_eq!(
            from_bus(
                "bus.ask_human",
                &json!({"question": "keep it?\nplease"}),
                &json!({})
            )
            .as_deref(),
            Some("asks: keep it?")
        );
        assert_eq!(
            from_bus(
                "bus.spawn",
                &json!({"template": "dev", "name": "w2"}),
                &json!({})
            )
            .as_deref(),
            Some("spawn w2")
        );
        assert_eq!(
            from_bus(
                "bus.spawn",
                &json!({"template": "dev"}),
                &json!({"name": "w7"})
            )
            .as_deref(),
            Some("spawn w7")
        );
        assert_eq!(
            from_bus("bus.card_update", &json!({"card": "T4"}), &json!({})).as_deref(),
            Some("card T4 updated")
        );
        assert_eq!(from_bus("bus.status", &json!({}), &json!({})), None);
    }

    #[test]
    fn text_is_one_line_and_cut_by_characters() {
        assert_eq!(first_line("first\nsecond"), "first");
        assert_eq!(clip("  a\n b  "), "a");
        let long = "中".repeat(200);
        assert_eq!(clip(&long).chars().count(), MAX_ACTIVITY_CHARS);
        let update = json!({"sessionUpdate": "tool_call", "title": long});
        assert_eq!(
            from_update(&update, Role::Worker)
                .expect("activity")
                .chars()
                .count(),
            MAX_ACTIVITY_CHARS
        );
    }

    #[test]
    fn the_throttle_allows_one_change_per_window_and_keeps_the_last_pending() {
        let mut throttle = ActivityThrottle::default();
        assert!(throttle.record(100, 2_000), "first change is immediate");
        assert!(!throttle.record(200, 2_000));
        assert_eq!(throttle.pending(), Some(2_100));
        assert!(!throttle.is_due(2_099));
        assert!(throttle.is_due(2_100));
        throttle.flushed(2_100);
        assert!(!throttle.is_due(2_100));
        assert!(
            !throttle.record(2_900, 2_000),
            "a flush starts a fresh window"
        );
        assert!(throttle.record(4_100, 2_000), "a later window opens again");
    }

    #[test]
    fn unchanged_text_does_not_reopen_the_window_but_still_counts_as_a_source() {
        let mut participant = Participant::new("w1", Role::Worker);
        assert!(participant.observe_activity("same".to_string(), 100, 2_000));
        assert!(!participant.observe_activity("same".to_string(), 200, 2_000));
        assert_eq!(
            participant.activity.as_ref().map(|activity| activity.at),
            Some(100)
        );
        assert_eq!(participant.activity_throttle.pending(), None);
        assert!(participant.turn_activity);
        assert!(!participant.observe_activity("next".to_string(), 300, 2_000));
        assert_eq!(participant.activity_throttle.pending(), Some(2_100));
        participant.set_state(super::super::ParticipantState::Working);
        assert_eq!(participant.activity_throttle.pending(), None);
    }

    #[test]
    fn a_zero_interval_never_throttles() {
        let mut throttle = ActivityThrottle::default();
        assert!(throttle.record(1, 0));
        assert!(throttle.record(1, 0));
    }
}
