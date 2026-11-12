/// chartools_core 对外出口 —— app 只从这里 import，不碰 `lib/src/`。
///
/// 分层与 README「仓库结构」一致：models 是采集/流水线的数据契约，
/// jev_client 是模型路由的底层件（HTTP、协议、异常），persona_kb 是
/// 人设/台账，safety 是安全策略，config 是三条路由的配置与端点推导，
/// pipeline 是判断 → 起草 → 排序 → 复查，scenarios 是场景模板。
///
/// export 清单与包内目录一一对应、按目录字母序排列；新增文件必须挂进
/// 这里，否则 app 层看不到。`src/` 下的相对路径不对外承诺。
///
/// pipeline 下的 reply_prompt / reply_review / judge_client /
/// reply_client / jev_client 五个文件是回复链路的入口，与既有支撑文件
/// （intensity 档位、strategy_order 排序、reply_cache_key 缓存键）共同
/// 构成完整链路 —— barrel 一个不落地全导出。
library;

export 'src/config/jev_config.dart';
export 'src/jev_client/api_exception.dart';
export 'src/jev_client/chat_judge.dart';
export 'src/jev_client/http_json.dart';
export 'src/jev_client/http_scope.dart';
export 'src/jev_client/jev_questions.dart';
export 'src/jev_client/json_slice.dart';
export 'src/jev_client/jsonx.dart';
export 'src/jev_client/judge_answers.dart';
export 'src/jev_client/judge_retry.dart';
export 'src/jev_client/routes.dart';
export 'src/jev_client/stream_text.dart';
export 'src/models/models.dart';
// 文档导入两件套按 barrel 头部规则挂载（独立复核补挂：导入丢弃计数要让
// app 预览层能如实告知「丢了什么」，见 DocImportOutcome）。
export 'src/persona_kb/doc_import/doc_importer.dart';
export 'src/persona_kb/doc_import/doc_parsers.dart';
export 'src/persona_kb/domain_brief.dart';
// #6/#12 同一先例（最小越界，已在交付 notes 声明）：专家库三件套按 barrel
// 头部规则「新增文件必须挂进这里」挂载，否则 app 层看不到专家目录/资产包/套用。
export 'src/persona_kb/expert_apply.dart';
export 'src/persona_kb/expert_catalog.dart';
export 'src/persona_kb/expert_pack.dart';
export 'src/persona_kb/kb_models.dart';
// #12（W4 知识库页写手的最小越界，已在交付 notes 声明）：W1 新增的 KbStore
// 必须挂进 barrel，否则 app 层看不到 —— 与下方 #6 的先例同一处理。
export 'src/persona_kb/kb_store.dart';
export 'src/persona_kb/ledger.dart';
// #12（W4 最小越界）：W1 新增的 LexicalSearch 挂 barrel，理由同上。
export 'src/persona_kb/lexical_search.dart';
export 'src/persona_kb/persona_card.dart';
// #6（交互写手的最小越界，已在交付 notes 声明）：C 的新文件按 barrel 头部
// 规则「新增文件必须挂进这里」挂载，否则 app 层看不到 PreferenceProfile。
export 'src/persona_kb/preference_profile.dart';
export 'src/persona_kb/style_profile.dart';
export 'src/persona_kb/style_source.dart';
export 'src/persona_kb/topic_scope.dart';
export 'src/pipeline/intensity.dart';
export 'src/pipeline/jev_client.dart';
export 'src/pipeline/judge_client.dart';
export 'src/pipeline/reply_cache_key.dart';
export 'src/pipeline/reply_client.dart';
export 'src/pipeline/reply_prompt.dart';
export 'src/pipeline/reply_review.dart';
export 'src/pipeline/strategy_order.dart';
export 'src/pipeline/usage_stats.dart';
export 'src/safety/safety_gate.dart';
export 'src/scenarios/scenario.dart';
