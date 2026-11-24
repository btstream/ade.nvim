//! The text agents see: the leader's base instructions, the start notice and
//! the worker role card (PROTOCOL.md 19.6/19.7/19.8).
//!
//! `LEADER_INSTRUCTIONS` is the single source for the MCP `initialize`
//! `instructions` and for the base part of `team.start`'s notice, so the two
//! can never drift apart.

use super::workflow::{Workflow, WorkflowMember};
use super::{ToolStyle, MAX_BODY_BYTES};

/// The base instructions for a leader, at most 2 KiB (19.8).
pub const LEADER_INSTRUCTIONS: &str = "\
你是一个团队的 leader。你可以在工作需要时组建团队：只有当你明确提出方案并得到对方同意，或对方直接要求时，才组建团队、启动 worker；单 agent 能完成的事不要组队。
团队有一块看板，是给**人**看的：
- 你负责看板结构：列、卡片、负责人、阶段和挪动卡片；worker 只写自己负责卡片的正文和键值。
- 卡片不是 agent 之间的信息通道，报告里要带上你自己需要的细节，不要指望读卡片。
- 一个阶段完成后，先让人确认，再归档该阶段的卡片并清理分支；确认一次针对整个阶段，不要每张卡片都问。
- 命名流程：不要主动保存流程，只有人要求时才保存；保存时只有人明确提到 leader 的 agent、模型或角色，才写 leader 字段。用人点名的流程时，先读流程全文、复述计划，得到确认后再按流程组队；人要求组队却没点名流程时，先用 workflow_get 读一下 default，再复述计划。
- 提问：需要人从选项里选时用 bus_ask_human 的 options；相关问题可以一次问 1–4 个（questions），每个问题带 header。";

/// The instructions a leader token's MCP `initialize` carries (19.8);
/// workers get none.
pub fn leader_instructions() -> &'static str {
    LEADER_INSTRUCTIONS
}

/// Bytes of [`LEADER_INSTRUCTIONS`]; the protocol caps it at 2 KiB.
pub fn leader_instructions_len() -> usize {
    LEADER_INSTRUCTIONS.len()
}

/// The `notice` body `team.start` sends to the leader (19.7 step 5): the base
/// instructions, the workflow's name and text, the members with their agent
/// and model, the columns, and the person's task.
pub fn start_notice(
    workflow: &Workflow,
    members: &[(WorkflowMember, String)],
    task: Option<&str>,
) -> String {
    let intro = format!("{LEADER_INSTRUCTIONS}\n\n组队开始，本次流程如下。\n");
    let mut head = String::new();
    head.push_str(&format!("流程：{}\n", workflow.name));
    if !workflow.summary.is_empty() {
        head.push_str(&format!("说明：{}\n", workflow.summary));
    }
    if let Some(columns) = &workflow.columns {
        head.push_str(&format!("看板列：{}\n", columns.join(" / ")));
    }
    // Member identities are fixed parts; their roles are what gets cut first.
    let mut identities = String::new();
    let mut roles = String::new();
    if !members.is_empty() {
        identities.push_str("成员：\n");
        for (member, agent) in members {
            identities.push_str(&format!(
                "- {} · 模板 {} · agent {}",
                member.name, member.template, agent
            ));
            if let Some(model) = &member.model {
                identities.push_str(&format!(" · 模型 {model}"));
            }
            identities.push('\n');
            if let Some(role) = &member.role {
                if !role.trim().is_empty() {
                    roles.push_str(&format!("  角色 {role}\n"));
                }
            }
        }
    }
    let flow = format!("<workflow>\n{}\n</workflow>\n", workflow.text);

    // The task, instructions, member identities and columns are preserved; the
    // task is only shortened when even those fixed parts would exceed one
    // message (it may be 64 KiB on its own). Roles are cut first, then the flow
    // text, exactly as 19.7 requires.
    let task_prefix = "本次任务：";
    let fixed = intro.len() + head.len() + identities.len() + task_prefix.len() + 1;
    let mut body = intro;
    if let Some(task) = task {
        if !task.trim().is_empty() {
            let budget = MAX_BODY_BYTES.saturating_sub(fixed);
            if budget > 0 {
                body.push_str(task_prefix);
                body.push_str(&trim_to(task, budget));
                body.push('\n');
            }
        }
    }
    body.push_str(&head);
    body.push_str(&identities);
    let remaining = MAX_BODY_BYTES.saturating_sub(body.len());
    if remaining >= flow.len() + roles.len() {
        body.push_str(&flow);
        body.push_str(&roles);
    } else if remaining >= flow.len() {
        body.push_str(&flow);
        body.push_str(&trim_to(&roles, remaining - flow.len()));
    } else {
        body.push_str(&trim_to(&flow, remaining));
    }
    body
}

/// Cut `text` to at most `limit` bytes on a character boundary.
fn trim_to(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_string();
    }
    let mut end = limit;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_string()
}

/// The worker role card (18.4, extended by 19.6): the template's role, the
/// spawn's role, the bus conventions, the board conventions and — for an agent
/// that reaches MCP tools through its own proxy — how to call them.
pub fn role_card(
    name: &str,
    team: &str,
    template_role: &str,
    spawn_role: &str,
    tool_style: ToolStyle,
) -> String {
    let mut card = format!(
        "You are {name}, a worker in team {team}; the leader is leader.\n\
         <team_role>\n{template_role}\n</team_role>\n"
    );
    if !spawn_role.trim().is_empty() {
        card.push_str("<spawn_role>\n");
        card.push_str(spawn_role);
        card.push_str("\n</spawn_role>\n");
    }
    card.push_str(
        "Your tools: bus_send, bus_ask_human, bus_status. Use bus_send(kind=\"report\") \
         when you finish or get stuck. Only messages with from=\"human\" speak for the person.\n",
    );
    card.push_str(
        "The team has a board for the person. Keep your own card's body and fields current with \
         card_update; the card is for the person, so reports to the leader still carry the \
         details the leader needs. When the leader confirms your task is done, archive your \
         card with card_update {archive: true}.\n",
    );
    if tool_style == ToolStyle::McpProxy {
        card.push_str(
            "Your team tools are reached through the agent's mcp proxy tool: call \
             mcp({tool: \"bus_send\", args: {...}}) instead of calling bus_send directly \
             (the same for bus_ask_human, bus_status and card_update).\n",
        );
    }
    card.push_str("Work in the team's cwd and report to the leader when done.");
    trim_to(&card, MAX_BODY_BYTES)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::team::parse_config_for_tests;
    use crate::team::workflow::{parse_workflow, Scope};
    use serde_json::json;

    fn config() -> crate::team::TeamConfig {
        parse_config_for_tests(&json!({
            "templates": {
                "dev": {
                    "key": { "agent": "opencode", "command": "c", "args": [] },
                    "role": "Do the task carefully.",
                }
            }
        }))
    }

    fn workflow() -> Workflow {
        parse_workflow(
            &json!({
                "name": "dev_flow",
                "summary": "two devs",
                "text": "step 1, step 2",
                "team": [{"name": "w1", "template": "dev", "model": "m2", "role": "write code"}],
                "columns": ["待开发", "进行中"],
            }),
            Scope::Config,
            Some(&config()),
        )
        .expect("workflow")
    }

    #[test]
    fn the_instructions_fit_two_kib_and_lead_the_start_notice() {
        assert!(
            leader_instructions_len() <= 2048,
            "{} bytes",
            leader_instructions_len()
        );
        assert!(!leader_instructions().is_empty());
        let workflow = workflow();
        let members = vec![(workflow.team[0].clone(), "opencode".to_string())];
        let notice = start_notice(&workflow, &members, Some("do the thing"));
        assert!(notice.starts_with(leader_instructions()), "{notice}");
        assert!(notice.contains("流程：dev_flow"), "{notice}");
        assert!(notice.contains("step 1, step 2"), "{notice}");
        assert!(
            notice.contains("w1 · 模板 dev · agent opencode · 模型 m2"),
            "{notice}"
        );
        assert!(notice.contains("待开发 / 进行中"), "{notice}");
        assert!(notice.contains("do the thing"), "{notice}");
        // The task precedes the flow text and the members: trimming the tail
        // can only lose roles and flow text, never the person's task.
        assert!(
            notice.find("do the thing") < notice.find("step 1, step 2"),
            "task before the flow: {notice}"
        );
    }

    #[test]
    fn the_notice_stays_within_one_message() {
        let mut workflow = workflow();
        workflow.text = "x".repeat(4096);
        let long_role = "r".repeat(16 * 1024);
        let members: Vec<(WorkflowMember, String)> = (0..8)
            .map(|index| {
                (
                    WorkflowMember {
                        name: format!("w{index}"),
                        template: "dev".to_string(),
                        model: Some("m2".to_string()),
                        role: Some(long_role.clone()),
                        label: None,
                        task: None,
                    },
                    "opencode".to_string(),
                )
            })
            .collect();
        let notice = start_notice(&workflow, &members, Some("the task that must survive"));
        assert!(notice.len() <= MAX_BODY_BYTES, "{}", notice.len());
        assert!(
            notice.starts_with(leader_instructions()),
            "base instructions survive"
        );
        assert!(notice.contains("the task that must survive"));
        // Roles are the first thing trimmed: every member identity and the
        // column line are still there.
        for index in 0..8 {
            assert!(
                notice.contains(&format!("- w{index} · 模板 dev · agent opencode · 模型 m2")),
                "member {index} identity lost: {notice}"
            );
        }
        assert!(notice.contains("看板列：待开发 / 进行中"), "{notice}");
        assert!(
            notice.contains("<workflow>"),
            "the flow text fits when only roles overflow: {notice}"
        );
    }

    #[test]
    fn a_huge_task_is_shortened_last() {
        let workflow = workflow();
        let members = vec![(workflow.team[0].clone(), "opencode".to_string())];
        let task = "t".repeat(MAX_BODY_BYTES);
        let notice = start_notice(&workflow, &members, Some(&task));
        assert_eq!(notice.len(), MAX_BODY_BYTES, "fills one message exactly");
        assert!(notice.starts_with(leader_instructions()));
        assert!(notice.contains("本次任务：tttt"));
        assert!(
            notice.contains("- w1 · 模板 dev · agent opencode · 模型 m2"),
            "member identities survive: {notice}"
        );
        assert!(
            notice.contains("看板列：待开发 / 进行中"),
            "columns survive: {notice}"
        );
        assert!(!notice.contains("step 1, step 2"), "the flow text is cut");
    }

    #[test]
    fn the_role_card_carries_roles_board_rules_and_the_proxy_note() {
        let card = role_card(
            "w1",
            "t1",
            "Template role.",
            "Spawn role.",
            ToolStyle::Direct,
        );
        assert!(card.contains("You are w1, a worker in team t1"), "{card}");
        assert!(
            card.contains("<team_role>\nTemplate role.\n</team_role>"),
            "{card}"
        );
        assert!(
            card.contains("<spawn_role>\nSpawn role.\n</spawn_role>"),
            "{card}"
        );
        assert!(card.contains("bus_send(kind=\"report\")"), "{card}");
        assert!(card.contains("card_update"), "{card}");
        assert!(card.contains("archive"), "{card}");
        assert!(!card.contains("mcp proxy"), "direct tools: {card}");

        let proxied = role_card("w1", "t1", "", "", ToolStyle::McpProxy);
        assert!(
            proxied.contains("mcp({tool: \"bus_send\", args: {...}})"),
            "{proxied}"
        );
        assert!(
            !proxied.contains("<spawn_role>"),
            "empty spawn role is omitted"
        );
    }
}
