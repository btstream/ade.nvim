//! Named workflows (PROTOCOL.md 19.1/19.5).
//!
//! A workflow is text the leader follows plus the team composition it names;
//! the service only validates, stores, resolves and hands it back. Nothing in
//! here runs a state machine.
//!
//! A name resolves in the order `config` > `project` > `user` > `builtin`.
//! The built-in `default` always exists; a configured one replaces it. Stored
//! workflows live in the event log database (19.11) and are keyed by scope and
//! by the team cwd's git project key, so the worktrees of one repository share
//! project workflows.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::{now_ms, valid_name, TeamConfig, TeamError, MAX_ROLE_BYTES};

/// `workflow.text` is at most 4 KiB (19.1).
pub const MAX_TEXT_BYTES: usize = 4 * 1024;
/// `summary` is one line of 1..120 characters.
pub const MAX_SUMMARY_CHARS: usize = 120;
/// A workflow names 0..8 workers.
pub const MAX_MEMBERS: usize = 8;
/// `columns` is 1..16 unique titles of 1..40 characters.
pub const MAX_COLUMNS: usize = 16;
pub const MAX_COLUMN_CHARS: usize = 40;
/// A member's `task` is at most 64 KiB.
pub const MAX_TASK_BYTES: usize = 64 * 1024;

/// Where a workflow came from (19.1). Results only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Scope {
    /// The team's configuration (`team.configure`), read-only.
    Config,
    /// Stored in the database for one git project.
    Project,
    /// Stored in the database for every project.
    User,
    /// The built-in `default`.
    Builtin,
}

impl Scope {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Config => "config",
            Self::Project => "project",
            Self::User => "user",
            Self::Builtin => "builtin",
        }
    }

    /// The scopes `workflow_save` may write (19.5).
    pub fn parse_stored(value: &str) -> Option<Self> {
        match value {
            "project" => Some(Self::Project),
            "user" => Some(Self::User),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkflowLeader {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkflowMember {
    pub name: String,
    pub template: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
}

/// A resolved workflow, as `workflow_get`/`team.workflows` return it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Workflow {
    pub name: String,
    pub summary: String,
    /// Resolved text: the stored one, or the built-in default's.
    #[serde(default)]
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub leader: Option<WorkflowLeader>,
    #[serde(default)]
    pub team: Vec<WorkflowMember>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub columns: Option<Vec<String>>,
    pub scope: Scope,
}

impl Workflow {
    /// The wire form, `scope` included (results only).
    pub fn to_json(&self) -> Value {
        let mut out = json!({
            "name": self.name,
            "summary": self.summary,
            "text": self.text,
            "team": self.team,
            "scope": self.scope.as_str(),
        });
        if let Some(leader) = &self.leader {
            out["leader"] = json!(leader);
        }
        if let Some(columns) = &self.columns {
            out["columns"] = json!(columns);
        }
        out
    }

    /// The default board columns the built-in flow uses (19.1).
    pub fn default_columns() -> Vec<String> {
        ["待开发", "进行中", "审查中", "等你决定"]
            .iter()
            .map(|title| title.to_string())
            .collect()
    }
}

/// The text of the built-in default flow (docs/w0-team-dashboard-draft.md 2.1).
pub const DEFAULT_TEXT: &str = "\
1. 你提出需求后，leader 做设计，把工作分成若干阶段，每个阶段拆成任务并在看板上建卡（卡片的 stage 写阶段名）。\
默认列：待开发 / 进行中 / 审查中 / 等你决定；等你决定只放需要你拍板的问题，不放“等提交”的卡片。
2. leader 按需启动 worker，每张卡片指定负责人，发 task 消息。worker 在自己的 worktree 里开发，进度写在卡片上。
3. worker 做完后 report；leader 审查改动、跑测试。不通过就发 review 打回，卡片回到进行中。
4. 单张卡片通过后不问人：leader 把这个 worker 的分支合并到本阶段的集成分支（例如 ade/<team>/<stage>，在单独的 worktree 里合并，不改动主工作区的 HEAD），然后给 worker 发完成确认；worker 归档卡片。如果 worker 已经退出，由 leader 归档。
5. 阶段完成后一次性问人：本阶段的卡片都归档后，leader 汇总这一阶段做了什么（每张卡片的标题和结论、集成分支上的测试结果、需要你注意的地方），请你确认提交。
6. 你确认后，leader 把集成分支合并进主分支、清理本阶段的 worktree 和 worker 分支；你不同意时，按你的意见在下一轮里修改，或者放弃整个集成分支。
7. 你也可以事先授权“阶段完成后直接提交”，那第 5 步只汇报、不等确认。";

/// The built-in `default` workflow (19.1).
pub fn builtin_default() -> Workflow {
    Workflow {
        name: "default".to_string(),
        summary:
            "默认流程：leader 设计与建卡，worker 在 worktree 里开发，审查后按阶段合并并确认提交"
                .to_string(),
        text: DEFAULT_TEXT.to_string(),
        leader: None,
        team: Vec::new(),
        columns: Some(Workflow::default_columns()),
        scope: Scope::Builtin,
    }
}

/// Validate a workflow on the wire (19.1). `scope` is the source the caller is
/// about to store it as; `config` checks member templates and models against
/// the team's configuration (pass `None` for a lenient structural check, as
/// when loading stored workflows whose templates may be gone).
pub fn parse_workflow(
    value: &Value,
    scope: Scope,
    config: Option<&TeamConfig>,
) -> Result<Workflow, TeamError> {
    let object = value
        .as_object()
        .ok_or_else(|| TeamError::invalid("workflow must be an object"))?;
    let name = string_field(object.get("name"), "workflow.name")?;
    if !valid_name(&name) {
        return Err(TeamError::invalid(
            "workflow.name must match [a-z0-9][a-z0-9_-]{0,31}",
        ));
    }
    let summary = string_field(object.get("summary"), "workflow.summary")?;
    if summary.is_empty()
        || summary.chars().count() > MAX_SUMMARY_CHARS
        || summary.contains('\n')
        || summary.contains('\r')
    {
        return Err(TeamError::invalid(
            "workflow.summary must be one line of 1..120 characters",
        ));
    }
    let text = match object.get("text") {
        None | Some(Value::Null) => DEFAULT_TEXT.to_string(),
        Some(value) => {
            let text = value
                .as_str()
                .ok_or_else(|| TeamError::invalid("workflow.text must be a string"))?;
            if text.len() > MAX_TEXT_BYTES {
                return Err(TeamError::invalid("workflow.text is longer than 4 KiB"));
            }
            text.to_string()
        }
    };
    let leader = match object.get("leader") {
        None | Some(Value::Null) => None,
        Some(value) => Some(parse_leader(value)?),
    };
    let mut team = Vec::new();
    match object.get("team") {
        None | Some(Value::Null) => {}
        Some(Value::Array(members)) => {
            if members.len() > MAX_MEMBERS {
                return Err(TeamError::invalid("workflow.team has more than 8 entries"));
            }
            if let Some(config) = config {
                for (index, member) in members.iter().enumerate() {
                    team.push(parse_member(member, index, &team, Some(config))?);
                }
            } else {
                for (index, member) in members.iter().enumerate() {
                    team.push(parse_member(member, index, &team, None)?);
                }
            }
        }
        Some(_) => return Err(TeamError::invalid("workflow.team must be an array")),
    }
    let columns = match object.get("columns") {
        None | Some(Value::Null) => None,
        Some(value) => Some(parse_columns(value)?),
    };
    Ok(Workflow {
        name,
        summary,
        text,
        leader,
        team,
        columns,
        scope,
    })
}

fn string_field(value: Option<&Value>, field: &str) -> Result<String, TeamError> {
    match value {
        Some(Value::String(text)) => Ok(text.clone()),
        Some(_) => Err(TeamError::invalid(format!("{field} must be a string"))),
        None => Err(TeamError::invalid(format!("{field} is required"))),
    }
}

fn optional_string_field(value: Option<&Value>, field: &str) -> Result<Option<String>, TeamError> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(_) => Err(TeamError::invalid(format!("{field} must be a string"))),
    }
}

fn parse_leader(value: &Value) -> Result<WorkflowLeader, TeamError> {
    let object = value
        .as_object()
        .ok_or_else(|| TeamError::invalid("workflow.leader must be an object"))?;
    let role = optional_string_field(object.get("role"), "workflow.leader.role")?;
    if role
        .as_ref()
        .is_some_and(|role| role.len() > MAX_ROLE_BYTES)
    {
        return Err(TeamError::invalid(
            "workflow.leader.role is longer than 16 KiB",
        ));
    }
    Ok(WorkflowLeader {
        agent: optional_string_field(object.get("agent"), "workflow.leader.agent")?,
        model: optional_string_field(object.get("model"), "workflow.leader.model")?,
        role,
    })
}

fn parse_member(
    value: &Value,
    index: usize,
    previous: &[WorkflowMember],
    config: Option<&TeamConfig>,
) -> Result<WorkflowMember, TeamError> {
    let prefix = format!("workflow.team[{index}]");
    let object = value
        .as_object()
        .ok_or_else(|| TeamError::invalid(format!("{prefix} must be an object")))?;
    let name = string_field(object.get("name"), &format!("{prefix}.name"))?;
    if !valid_name(&name) {
        return Err(TeamError::invalid(format!(
            "{prefix}.name must match [a-z0-9][a-z0-9_-]{{0,31}}"
        )));
    }
    if name == "leader" || name == "human" {
        return Err(TeamError::invalid(format!(
            "{prefix}.name must not be leader or human"
        )));
    }
    if previous.iter().any(|member| member.name == name) {
        return Err(TeamError::invalid(format!(
            "{prefix}.name {name} is already used"
        )));
    }
    let template = string_field(object.get("template"), &format!("{prefix}.template"))?;
    let model = optional_string_field(object.get("model"), &format!("{prefix}.model"))?;
    let role = optional_string_field(object.get("role"), &format!("{prefix}.role"))?;
    if role
        .as_ref()
        .is_some_and(|role| role.len() > MAX_ROLE_BYTES)
    {
        return Err(TeamError::invalid(format!(
            "{prefix}.role is longer than 16 KiB"
        )));
    }
    let task = optional_string_field(object.get("task"), &format!("{prefix}.task"))?;
    if task
        .as_ref()
        .is_some_and(|task| task.len() > MAX_TASK_BYTES)
    {
        return Err(TeamError::invalid(format!(
            "{prefix}.task is longer than 64 KiB"
        )));
    }
    if let Some(config) = config {
        let Some(template_config) = config.templates.get(&template) else {
            return Err(TeamError::invalid(format!(
                "{prefix}.template {template} is unknown"
            )));
        };
        if let Some(model) = &model {
            if !template_config.models.is_empty()
                && !template_config
                    .models
                    .iter()
                    .any(|allowed| allowed == model)
            {
                return Err(TeamError::invalid(format!(
                    "{prefix}.model {model} is not allowed by template {template}"
                )));
            }
        }
    }
    Ok(WorkflowMember {
        name,
        template,
        model,
        role,
        task,
    })
}

fn parse_columns(value: &Value) -> Result<Vec<String>, TeamError> {
    let Some(items) = value.as_array() else {
        return Err(TeamError::invalid("workflow.columns must be an array"));
    };
    if items.is_empty() || items.len() > MAX_COLUMNS {
        return Err(TeamError::invalid(
            "workflow.columns must have 1..16 entries",
        ));
    }
    let mut columns: Vec<String> = Vec::new();
    for (index, item) in items.iter().enumerate() {
        let Some(title) = item.as_str() else {
            return Err(TeamError::invalid(format!(
                "workflow.columns[{index}] must be a string"
            )));
        };
        let count = title.chars().count();
        if count == 0 || count > MAX_COLUMN_CHARS {
            return Err(TeamError::invalid(format!(
                "workflow.columns[{index}] must be 1..40 characters"
            )));
        }
        if columns.iter().any(|column| column == title) {
            return Err(TeamError::invalid(format!(
                "workflow.columns[{index}] {title} is already used"
            )));
        }
        columns.push(title.to_string());
    }
    Ok(columns)
}

/// Stored (project and user) workflows, keyed by scope, project and name.
#[derive(Debug, Default)]
pub struct StoredWorkflows {
    rows: BTreeMap<(Scope, String, String), Workflow>,
}

impl StoredWorkflows {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert(&mut self, project: &str, workflow: Workflow) {
        let project = if workflow.scope == Scope::User {
            String::new()
        } else {
            project.to_string()
        };
        self.rows
            .insert((workflow.scope, project, workflow.name.clone()), workflow);
    }

    /// Remove one stored workflow; returns the removed record.
    pub fn remove(&mut self, scope: Scope, project: &str, name: &str) -> Option<Workflow> {
        let project = if scope == Scope::User {
            String::new()
        } else {
            project.to_string()
        };
        self.rows.remove(&(scope, project, name.to_string()))
    }

    pub fn get(&self, scope: Scope, project: &str, name: &str) -> Option<&Workflow> {
        let project = if scope == Scope::User {
            String::new()
        } else {
            project.to_string()
        };
        self.rows.get(&(scope, project, name.to_string()))
    }

    /// Load rows from the database `(scope, project, name, json)`. A row that
    /// no longer parses is skipped, never fatal: workflows outlive teams and
    /// their templates (19.5).
    pub fn load(&mut self, rows: Vec<(String, String, String, String)>) {
        for (scope, project, name, json) in rows {
            let Some(scope) = Scope::parse_stored(&scope) else {
                continue;
            };
            let Ok(mut workflow) = serde_json::from_str::<Workflow>(&json) else {
                continue;
            };
            let project = if scope == Scope::User {
                String::new()
            } else {
                project
            };
            workflow.name = name.clone();
            workflow.scope = scope;
            self.rows.insert((scope, project, name), workflow);
        }
    }

    /// Every name visible from `project`, resolved and sorted by name.
    pub fn names(&self, project: &str) -> Vec<(String, Scope)> {
        let mut names: BTreeMap<String, Scope> = BTreeMap::new();
        for (scope, stored_project, name) in self.rows.keys() {
            let visible =
                *scope == Scope::User || (*scope == Scope::Project && stored_project == project);
            if !visible {
                continue;
            }
            match names.get(name) {
                // Project shadows user.
                Some(Scope::Project) => {}
                _ => {
                    names.insert(name.clone(), *scope);
                }
            }
        }
        names.into_iter().collect()
    }
}

/// Resolve `name` for a team: config > project > user > builtin (19.1).
pub fn resolve(
    config: &TeamConfig,
    stored: &StoredWorkflows,
    project: &str,
    name: &str,
) -> Option<Workflow> {
    if let Some(workflow) = config.workflows.get(name) {
        return Some(workflow.clone());
    }
    if let Some(workflow) = stored.get(Scope::Project, project, name) {
        return Some(workflow.clone());
    }
    if let Some(workflow) = stored.get(Scope::User, "", name) {
        return Some(workflow.clone());
    }
    if name == "default" {
        return Some(builtin_default());
    }
    None
}

/// Every name visible from `project` once, resolved, sorted by name (19.5).
pub fn list(config: &TeamConfig, stored: &StoredWorkflows, project: &str) -> Vec<Workflow> {
    let mut names: BTreeMap<String, ()> = BTreeMap::new();
    for name in config.workflows.keys() {
        names.insert(name.clone(), ());
    }
    for (name, _) in stored.names(project) {
        names.insert(name, ());
    }
    names.insert("default".to_string(), ());
    names
        .into_keys()
        .filter_map(|name| resolve(config, stored, project, &name))
        .collect()
}

/// The team's workflow table with the built-in `default` in it when nothing
/// else defines it: the view `bus.status` and `team.workflows` use.
pub fn short_list(config: &TeamConfig, stored: &StoredWorkflows, project: &str) -> Vec<Value> {
    list(config, stored, project)
        .iter()
        .map(|workflow| {
            json!({
                "name": workflow.name,
                "summary": workflow.summary,
                "scope": workflow.scope.as_str(),
            })
        })
        .collect()
}

/// The project key of a cwd: the canonical path of
/// `git rev-parse --git-common-dir`, or the canonical cwd when that fails
/// (19.1). Worktrees of one repository therefore share project workflows.
pub async fn project_key(cwd: &str) -> String {
    if let Some(key) = git_common_dir(cwd).await {
        return key;
    }
    canonical_cwd(cwd)
}

/// The canonical cwd; the documented fallback project key.
pub fn canonical_cwd(cwd: &str) -> String {
    std::fs::canonicalize(cwd)
        .map(|path| path.to_string_lossy().to_string())
        .unwrap_or_else(|_| cwd.to_string())
}

async fn git_common_dir(cwd: &str) -> Option<String> {
    let args = ["rev-parse", "--git-common-dir"];
    let output = super::worktree::git(Path::new(cwd), &args).await.ok()?;
    if !output.ok {
        return None;
    }
    let raw = output.stdout.trim();
    if raw.is_empty() {
        return None;
    }
    let path = PathBuf::from(raw);
    let path = if path.is_absolute() {
        path
    } else {
        Path::new(cwd).join(path)
    };
    std::fs::canonicalize(path)
        .ok()
        .map(|path| path.to_string_lossy().to_string())
}

/// `updated_ms` for a stored workflow write.
pub fn updated_ms() -> u64 {
    now_ms()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::team::parse_config_for_tests;

    fn config() -> TeamConfig {
        parse_config_for_tests(&json!({
            "templates": {
                "dev": {
                    "key": { "agent": "a", "command": "c", "args": [] },
                    "role": "role",
                    "models": ["m1", "m2"],
                },
                "free": {
                    "key": { "agent": "b", "command": "c", "args": [] },
                }
            }
        }))
    }

    fn workflow(extra: Value) -> Value {
        let mut base = json!({
            "name": "dev_flow",
            "summary": "two devs",
        });
        if let (Value::Object(base), Value::Object(extra)) = (&mut base, extra) {
            for (key, value) in extra {
                base.insert(key, value);
            }
        }
        base
    }

    fn error(value: Value) -> TeamError {
        parse_workflow(&value, Scope::Project, Some(&config())).expect_err("must be rejected")
    }

    #[test]
    fn a_workflow_is_validated_field_by_field() {
        let ok = parse_workflow(&workflow(json!({})), Scope::Project, Some(&config()))
            .expect("valid workflow");
        assert_eq!(ok.text, DEFAULT_TEXT, "absent text is the built-in text");

        assert!(error(workflow(json!({"name": "Bad"})))
            .message
            .contains("workflow.name"));
        assert!(error(workflow(json!({"summary": ""})))
            .message
            .contains("workflow.summary"));
        assert!(error(workflow(json!({"summary": "a\nb"})))
            .message
            .contains("workflow.summary"));
        assert!(error(workflow(json!({"summary": "字".repeat(121)})))
            .message
            .contains("workflow.summary"));
        assert!(
            error(workflow(json!({"text": "x".repeat(MAX_TEXT_BYTES + 1)})))
                .message
                .contains("workflow.text")
        );
        assert!(error(workflow(
            json!({"leader": {"role": "x".repeat(MAX_ROLE_BYTES + 1)}})
        ))
        .message
        .contains("workflow.leader.role"));

        let too_many: Vec<Value> = (1..=9)
            .map(|index| json!({"name": format!("w{index}"), "template": "dev"}))
            .collect();
        assert!(error(workflow(json!({"team": too_many})))
            .message
            .contains("workflow.team"));

        let member = |name: &str| json!({"name": name, "template": "dev"});
        assert!(error(workflow(json!({"team": [member("Leader")]})))
            .message
            .contains("workflow.team[0].name"));
        assert!(error(workflow(json!({"team": [member("leader")]})))
            .message
            .contains("must not be leader"));
        assert!(
            error(workflow(json!({"team": [member("w1"), member("w1")]})))
                .message
                .contains("already used")
        );
        assert!(error(workflow(
            json!({"team": [{"name": "w1", "template": "nope"}]})
        ))
        .message
        .contains("is unknown"));
        assert!(error(workflow(json!({"team": [
            {"name": "w1", "template": "dev", "model": "m9"}
        ]})))
        .message
        .contains("is not allowed"));
        assert!(error(workflow(json!({"team": [
            {"name": "w1", "template": "dev", "role": "x".repeat(MAX_ROLE_BYTES + 1)}
        ]})))
        .message
        .contains("workflow.team[0].role"));
        assert!(error(workflow(json!({"team": [
            {"name": "w1", "template": "dev", "task": "x".repeat(MAX_TASK_BYTES + 1)}
        ]})))
        .message
        .contains("workflow.team[0].task"));

        assert!(error(workflow(json!({"columns": []})))
            .message
            .contains("workflow.columns"));
        assert!(error(workflow(json!({"columns": ["待开发", "待开发"]})))
            .message
            .contains("already used"));
        assert!(error(workflow(json!({"columns": ["x".repeat(41)]})))
            .message
            .contains("1..40 characters"));

        let columns: Vec<String> = (1..=17).map(|index| format!("c{index}")).collect();
        assert!(error(workflow(json!({"columns": columns})))
            .message
            .contains("1..16 entries"));
    }

    #[test]
    fn the_builtin_default_exists_and_a_config_workflow_replaces_it() {
        let mut teams_config = config();
        let builtin = resolve(&teams_config, &StoredWorkflows::new(), "/p", "default")
            .expect("builtin default");
        assert_eq!(builtin.scope, Scope::Builtin);
        assert_eq!(builtin.team.len(), 0);
        assert_eq!(
            builtin.columns,
            Some(Workflow::default_columns()),
            "the four default columns"
        );
        assert_eq!(
            builtin.columns.as_ref().unwrap(),
            &vec!["待开发", "进行中", "审查中", "等你决定"]
        );

        let configured = parse_workflow(
            &workflow(json!({"name": "default", "summary": "ours"})),
            Scope::Config,
            Some(&teams_config),
        )
        .expect("configured default");
        teams_config
            .workflows
            .insert("default".to_string(), configured);
        let resolved = resolve(&teams_config, &StoredWorkflows::new(), "/p", "default")
            .expect("configured default");
        assert_eq!(resolved.scope, Scope::Config);
        assert_eq!(resolved.summary, "ours");
    }

    #[test]
    fn resolution_is_config_then_project_then_user_then_builtin() {
        let mut config = config();
        let mut stored = StoredWorkflows::new();

        let mut project = parse_workflow(
            &workflow(json!({"summary": "project"})),
            Scope::Project,
            Some(&config),
        )
        .expect("project");
        stored.insert("/p", project.clone());
        let mut user = parse_workflow(
            &workflow(json!({"summary": "user"})),
            Scope::User,
            Some(&config),
        )
        .expect("user");
        stored.insert("/other", user.clone());

        let resolved = resolve(&config, &stored, "/p", "dev_flow").expect("project wins");
        assert_eq!(resolved.summary, "project");
        assert_eq!(resolved.scope, Scope::Project);
        // Another project sees the user one.
        let other = resolve(&config, &stored, "/q", "dev_flow").expect("user");
        assert_eq!(other.scope, Scope::User);
        assert_eq!(other.summary, "user");
        // Plus the builtin default and the configured one.
        let listed = list(&config, &stored, "/p");
        let names: Vec<&str> = listed
            .iter()
            .map(|workflow| workflow.name.as_str())
            .collect();
        assert_eq!(names, vec!["default", "dev_flow"]);
        assert_eq!(listed[1].summary, "project");

        project.summary = "configured".to_string();
        project.scope = Scope::Config;
        config.workflows.insert("dev_flow".to_string(), project);
        let resolved = resolve(&config, &stored, "/p", "dev_flow").expect("config wins");
        assert_eq!(resolved.scope, Scope::Config);
        user.summary = "user again".to_string();
        let listed = list(&config, &stored, "/p");
        assert_eq!(listed.len(), 2);
        assert_eq!(listed[1].summary, "configured");
    }

    #[test]
    fn stored_workflows_round_trip_and_skip_broken_rows() {
        let stored_workflow = parse_workflow(
            &workflow(json!({"team": [{"name": "w1", "template": "dev", "model": "m1"}]})),
            Scope::Project,
            Some(&config()),
        )
        .expect("workflow");
        let json = serde_json::to_string(&stored_workflow).expect("json");
        let mut stored = StoredWorkflows::new();
        stored.load(vec![
            (
                "project".to_string(),
                "/p".to_string(),
                "dev_flow".to_string(),
                json,
            ),
            (
                "user".to_string(),
                String::new(),
                "broken".to_string(),
                "{".to_string(),
            ),
        ]);
        let listed = list(&config(), &stored, "/p");
        assert_eq!(listed.len(), 2, "{listed:?}");
        assert_eq!(listed[1].team[0].model.as_deref(), Some("m1"));
        assert_eq!(listed[1].scope, Scope::Project);
    }

    #[test]
    fn the_short_list_is_name_summary_scope() {
        let config = config();
        let stored = StoredWorkflows::new();
        let short = short_list(&config, &stored, "/p");
        assert_eq!(short.len(), 1);
        assert_eq!(short[0]["name"], "default");
        assert_eq!(short[0]["scope"], "builtin");
        assert!(short[0]["summary"].as_str().is_some());
    }

    #[tokio::test]
    async fn a_worktree_and_its_repository_share_a_project_key() {
        let dir = std::env::temp_dir().join(format!(
            "nvim-ade-workflow-key-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let repo = dir.join("repo");
        std::fs::create_dir_all(&repo).expect("repo dir");
        let git = |args: &[&str]| {
            let output = std::process::Command::new("git")
                .arg("-C")
                .arg(&repo)
                .args(args)
                .env("GIT_AUTHOR_NAME", "ade test")
                .env("GIT_AUTHOR_EMAIL", "test@example.invalid")
                .env("GIT_COMMITTER_NAME", "ade test")
                .env("GIT_COMMITTER_EMAIL", "test@example.invalid")
                .output()
                .expect("git");
            assert!(
                output.status.success(),
                "git {args:?}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        };
        git(&["init", "-q"]);
        std::fs::write(repo.join("root.txt"), "root\n").expect("file");
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", "initial"]);
        let worktree = repo.join("..").join("repo-worktree");
        git(&[
            "worktree",
            "add",
            "-q",
            worktree.to_str().unwrap(),
            "-b",
            "wt",
            "HEAD",
        ]);

        let main_key = project_key(&repo.to_string_lossy()).await;
        let worktree_key = project_key(&worktree.to_string_lossy()).await;
        assert_eq!(main_key, worktree_key, "worktrees share project workflows");
        assert!(main_key.ends_with(".git"), "{main_key}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_plain_directory_falls_back_to_its_canonical_path() {
        let dir = std::env::temp_dir().join(format!(
            "nvim-ade-workflow-plain-{}-{}",
            std::process::id(),
            now_ms()
        ));
        std::fs::create_dir_all(&dir).expect("dir");
        let key = project_key(&dir.to_string_lossy()).await;
        let canonical = std::fs::canonicalize(&dir).expect("canonical");
        assert_eq!(key, canonical.to_string_lossy());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
