//! Host-side arbitration for the optional intelligent view mode.
use aimonitor_core::{claude_code::Waiting, Entry, Provider};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::time::{Duration, Instant};

const MIN_DWELL: Duration = Duration::from_secs(2 * 60);
const MANUAL_HOLD: Duration = Duration::from_secs(10 * 60);
const VIEW_COOLDOWN: Duration = Duration::from_secs(10 * 60);
const EVENT_LIFETIME: Duration = Duration::from_secs(5 * 60);

#[derive(Clone, Debug)]
pub struct UsageSignal {
    pub id: String,
    pub used: f64,
    pub reset: Option<String>,
}

pub fn usage_signals(entry: &Entry) -> Vec<UsageSignal> {
    let mut values = Vec::new();
    if !entry.provider.uses_model_rows() || entry.extra_windows.is_empty() {
        values.extend([
            ("primary", &entry.primary), ("secondary", &entry.secondary), ("tertiary", &entry.tertiary),
        ].into_iter().filter_map(|(id, window)| window.as_ref().map(|window| UsageSignal {
            id: id.into(), used: window.used_percent,
            reset: window.resets_at.map(|date| date.to_rfc3339()),
        })));
    }
    let extra_slots = if entry.provider.uses_model_rows() && !entry.extra_windows.is_empty() {
        3
    } else {
        3usize.saturating_sub(values.len())
    };
    values.extend(entry.extra_windows.iter().take(extra_slots).map(|row| UsageSignal {
        id: format!("extra:{}", row.id),
        used: row.window.used_percent,
        reset: row.window.resets_at.map(|date| date.to_rfc3339()),
    }));
    values
}

struct Candidate {
    view: usize,
    priority: u8,
    at: Instant,
    claude_wait: Option<(String, Waiting, i64)>,
}

#[derive(Default)]
pub struct SmartSwitch {
    usage: HashMap<Provider, Vec<UsageSignal>>,
    plugins: HashMap<String, (BTreeMap<String, bool>, Instant)>,
    claude_code_waiting: Option<BTreeSet<(String, Waiting, i64)>>,
    pending: Vec<Candidate>,
    shown_at: HashMap<usize, Instant>,
    last_change: Option<Instant>,
    manual_until: Option<Instant>,
}

impl SmartSwitch {
    pub fn reset(&mut self, now: Instant) {
        *self = Self::default();
        self.last_change = Some(now);
    }

    pub fn touch(&mut self, now: Instant) {
        self.last_change = Some(now);
        self.manual_until = Some(now + MANUAL_HOLD);
        self.pending.clear();
    }

    pub fn observe_usage(&mut self, provider: Provider, current: Vec<UsageSignal>, views: &[Option<Provider>], now: Instant) {
        let Some(previous) = self.usage.get_mut(&provider) else {
            self.usage.insert(provider, current);
            return;
        };
        let mut priority = 0;
        for row in &current {
            let Some(old) = previous.iter_mut().find(|r| r.id == row.id) else {
                previous.push(row.clone());
                continue;
            };
            if !row.used.is_finite() || !(0.0..=100.0).contains(&row.used) { continue; }
            let mut row_priority = 0;
            if old.reset != row.reset && row.used + 5.0 < old.used {
                row_priority = 2;
            } else if row.used > old.used {
                if [80.0, 90.0, 100.0].iter().any(|&limit| old.used < limit && row.used >= limit) {
                    row_priority = 3;
                } else if row.used - old.used >= 5.0 {
                    row_priority = 1;
                }
            }
            priority = priority.max(row_priority);
            // Keep the anchor through small increases, so they can accumulate.
            if row_priority > 0 || row.used < old.used {
                *old = row.clone();
            }
        }
        if priority > 0 {
            for (index, assigned) in views.iter().enumerate() {
                if *assigned == Some(provider) {
                    self.enqueue(index, priority, now);
                }
            }
        }
    }

    pub fn observe_plugin(&mut self, id: &str, current: BTreeMap<String, bool>, views: &[Option<&str>], now: Instant, max_age: Duration) {
        let previous = self.plugins.insert(id.to_owned(), (current.clone(), now));
        let Some((previous, observed_at)) = previous else { return };
        if !now.checked_duration_since(observed_at).is_some_and(|age| age <= max_age) { return; }
        if current.iter().any(|(key, value)| *value && !previous.get(key).copied().unwrap_or(false)) {
            for (index, assigned) in views.iter().enumerate() {
                if *assigned == Some(id) { self.enqueue(index, 2, now); }
            }
        }
    }

    pub fn observe_claude_code(&mut self, waiting: Vec<(String, Waiting, i64)>, views: &[Option<&str>], now: Instant) {
        let current: BTreeSet<_> = waiting.into_iter().collect();
        let previous = self.claude_code_waiting.replace(current.clone());
        self.pending.retain(|candidate| candidate.claude_wait.as_ref()
            .is_none_or(|key| current.contains(key)));
        if let Some(previous) = previous {
            for key in current.difference(&previous) {
                for (index, assigned) in views.iter().enumerate() {
                    if *assigned == Some(aimonitor_core::claude_code::VIEW_ID) {
                        self.pending.push(Candidate {
                            view: index, priority: 2, at: now, claude_wait: Some(key.clone()),
                        });
                    }
                }
            }
        }
    }

    pub fn reset_plugin(&mut self, id: &str, views: &[Option<&str>]) {
        self.plugins.remove(id);
        self.pending.retain(|candidate| views.get(candidate.view).copied().flatten() != Some(id));
    }

    fn enqueue(&mut self, view: usize, priority: u8, now: Instant) {
        self.pending.push(Candidate { view, priority, at: now, claude_wait: None });
    }

    pub fn choose(&mut self, active: usize, now: Instant) -> Option<usize> {
        self.pending.retain(|c| now.duration_since(c.at) <= EVENT_LIFETIME);
        if self.manual_until.is_some_and(|until| now < until)
            || self.last_change.is_some_and(|at| now.duration_since(at) < MIN_DWELL) {
            return None;
        }
        let next = self.pending.iter()
            .filter(|c| c.view != active && self.shown_at.get(&c.view).is_none_or(|at| now.duration_since(*at) >= VIEW_COOLDOWN))
            .max_by_key(|c| (c.priority, std::cmp::Reverse(c.at)))
            .map(|c| c.view)?;
        self.pending.clear();
        self.last_change = Some(now);
        self.shown_at.insert(next, now);
        Some(next)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn plugin_fires_only_on_rising_edge_and_respects_cooldown() {
        let start = Instant::now();
        let mut smart = SmartSwitch::default();
        smart.reset(start);
        let views = [None, Some("weather")];
        let state = |rain| BTreeMap::from([("rain".into(), rain)]);
        smart.observe_plugin("weather", state(false), &views, start, Duration::from_secs(900));
        smart.observe_plugin("weather", state(true), &views, start, Duration::from_secs(900));
        assert_eq!(smart.choose(0, start + MIN_DWELL), Some(1));
        smart.observe_plugin("weather", state(true), &views, start + MIN_DWELL, Duration::from_secs(900));
        assert_eq!(smart.choose(0, start + MIN_DWELL + MIN_DWELL), None);
        smart.observe_plugin("weather", state(false), &views, start + MIN_DWELL + MIN_DWELL, Duration::from_secs(900));
        smart.observe_plugin("weather", state(true), &views, start + MIN_DWELL + MIN_DWELL, Duration::from_secs(900));
        assert_eq!(smart.choose(0, start + MIN_DWELL + MIN_DWELL), None);
    }

    #[test]
    fn plugin_replacement_clears_pending_events_and_uses_a_new_baseline() {
        let start = Instant::now();
        let mut smart = SmartSwitch::default();
        smart.reset(start);
        let views = [None, Some("weather")];
        let state = |rain| BTreeMap::from([("rain".into(), rain)]);
        smart.observe_plugin("weather", state(false), &views, start, Duration::from_secs(900));
        smart.observe_plugin("weather", state(true), &views, start, Duration::from_secs(900));
        smart.reset_plugin("weather", &views);
        smart.observe_plugin("weather", state(true), &views, start, Duration::from_secs(900));
        assert_eq!(smart.choose(0, start + MIN_DWELL), None);
        smart.observe_plugin("weather", state(false), &views, start + MIN_DWELL, Duration::from_secs(900));
        smart.observe_plugin("weather", state(true), &views, start + MIN_DWELL, Duration::from_secs(900));
        assert_eq!(smart.choose(0, start + MIN_DWELL), Some(1));
    }

    #[test]
    fn claude_code_waiting_fires_for_each_session_and_cancels_resolved_wait() {
        let start = Instant::now();
        let mut smart = SmartSwitch::default();
        smart.reset(start);
        let views = [None, Some(aimonitor_core::claude_code::VIEW_ID)];
        let wait = |id: &str, since| (id.to_owned(), Waiting::Permission, since);
        smart.observe_claude_code(vec![], &views, start);
        smart.observe_claude_code(vec![wait("a", 1)], &views, start + Duration::from_secs(1));
        assert_eq!(smart.choose(0, start + Duration::from_secs(1)), None);
        smart.observe_claude_code(vec![], &views, start + Duration::from_secs(2));
        assert_eq!(smart.choose(0, start + MIN_DWELL), None);
        smart.observe_claude_code(vec![wait("a", 3)], &views, start + MIN_DWELL);
        assert_eq!(smart.choose(0, start + MIN_DWELL), Some(1));
        smart.observe_claude_code(vec![wait("a", 3), wait("b", 4)], &views, start + MIN_DWELL);
        assert_eq!(smart.pending.len(), 1);
        smart.observe_claude_code(vec![wait("a", 3), wait("b", 4)], &views, start + MIN_DWELL);
        assert_eq!(smart.pending.len(), 1);
    }

    #[test]
    fn resolved_request_does_not_use_an_older_finished_session() {
        let start = Instant::now();
        let mut smart = SmartSwitch::default();
        smart.reset(start);
        let views = [None, Some(aimonitor_core::claude_code::VIEW_ID)];
        let done = ("a".to_owned(), Waiting::Done, 1);
        let permission = ("b".to_owned(), Waiting::Permission, 2);
        smart.observe_claude_code(vec![done.clone()], &views, start);
        smart.observe_claude_code(vec![done.clone(), permission], &views, start + Duration::from_secs(1));
        smart.observe_claude_code(vec![done], &views, start + Duration::from_secs(2));
        assert_eq!(smart.choose(0, start + MIN_DWELL), None);
    }

    #[test]
    fn older_wait_cannot_borrow_newer_candidates_lifetime() {
        let start = Instant::now();
        let mut smart = SmartSwitch::default();
        smart.reset(start);
        let views = [None, Some(aimonitor_core::claude_code::VIEW_ID)];
        let done = ("a".to_owned(), Waiting::Done, 1);
        let permission = ("b".to_owned(), Waiting::Permission, 2);
        smart.observe_claude_code(vec![], &views, start);
        smart.observe_claude_code(vec![done.clone()], &views, start + Duration::from_secs(1));
        smart.observe_claude_code(vec![done.clone(), permission], &views, start + Duration::from_secs(4 * 60));
        smart.observe_claude_code(vec![done], &views, start + Duration::from_secs(4 * 60 + 30));
        assert_eq!(smart.pending.len(), 1);
        assert_eq!(smart.choose(0, start + Duration::from_secs(8 * 60)), None);
    }

    #[test]
    fn plugin_event_after_stale_baseline_only_seeds_a_new_baseline() {
        let start = Instant::now();
        let mut smart = SmartSwitch::default();
        smart.reset(start);
        let views = [None, Some("weather")];
        let state = |rain| BTreeMap::from([("rain".into(), rain)]);
        let max_age = Duration::from_secs(900);
        smart.observe_plugin("weather", state(false), &views, start, max_age);
        smart.observe_plugin("weather", state(true), &views, start + max_age + Duration::from_secs(1), max_age);
        assert_eq!(smart.choose(0, start + max_age + Duration::from_secs(1)), None);
        smart.observe_plugin("weather", state(false), &views, start + max_age + Duration::from_secs(2), max_age);
        smart.observe_plugin("weather", state(true), &views, start + max_age + Duration::from_secs(3), max_age);
        assert_eq!(smart.choose(0, start + max_age + Duration::from_secs(3)), Some(1));
    }

    #[test]
    fn antigravity_uses_fixed_windows_only_without_model_extras() {
        use aimonitor_core::{ExtraWindow, Window};
        let window = Window { used_percent: 25.0, resets_at: None,
            window_minutes: Some(300), reset_description: None };
        let mut entry = Entry {
            provider: Provider::Antigravity, updated_at: None,
            primary: Some(window.clone()), secondary: None, tertiary: None,
            extra_windows: Vec::new(), login_method: None,
            credits: None, reset_credits: None,
        };
        assert_eq!(usage_signals(&entry)[0].id, "primary");
        entry.extra_windows.push(ExtraWindow {
            id: "model".into(), title: "Model".into(), window,
        });
        for index in 0..4 {
            entry.extra_windows.push(ExtraWindow {
                id: format!("model{index}"), title: "Model".into(),
                window: entry.primary.as_ref().unwrap().clone(),
            });
        }
        let signals = usage_signals(&entry);
        assert_eq!(signals.len(), 3);
        assert_eq!(signals[0].id, "extra:model");
        assert_eq!(signals[2].id, "extra:model1");
        entry.provider = Provider::Claude;
        assert_eq!(usage_signals(&entry).len(), 3);
    }

    #[test]
    fn gradual_usage_increase_reaches_the_significance_threshold() {
        let start = Instant::now();
        let mut smart = SmartSwitch::default();
        smart.reset(start);
        let views = [None, Some(Provider::Claude)];
        let sample = |value| vec![UsageSignal { id: "primary".into(), used: value, reset: None }];
        smart.observe_usage(Provider::Claude, sample(10.0), &views, start);
        smart.observe_usage(Provider::Claude, sample(12.0), &views, start);
        smart.observe_usage(Provider::Claude, sample(14.0), &views, start);
        assert_eq!(smart.choose(0, start + MIN_DWELL), None);
        smart.observe_usage(Provider::Claude, sample(16.0), &views, start + MIN_DWELL);
        assert_eq!(smart.choose(0, start + MIN_DWELL), Some(1));
    }

    #[test]
    fn edges_dwell_and_touch_hold() {
        let start = Instant::now();
        let mut smart = SmartSwitch::default();
        smart.reset(start);
        let views = [None, Some(Provider::DEFAULT)];
        let sample = |value| vec![UsageSignal { id: "primary".into(), used: value, reset: None }];
        smart.observe_usage(Provider::DEFAULT, sample(20.0), &views, start);
        smart.observe_usage(Provider::DEFAULT, sample(26.0), &views, start);
        assert_eq!(smart.choose(0, start + Duration::from_secs(30)), None);
        assert_eq!(smart.choose(0, start + MIN_DWELL), Some(1));
        smart.touch(start + MIN_DWELL);
        smart.observe_usage(Provider::DEFAULT, sample(90.0), &views, start + MIN_DWELL);
        assert_eq!(smart.choose(0, start + MIN_DWELL + Duration::from_secs(300)), None);
    }
}
