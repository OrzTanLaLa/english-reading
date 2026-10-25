/**
 * 与外部模型/工具交换数据的纯结构定义。
 * 这一层不依赖任何平台 API，将来可原样用于 Node 单测。
 */

/** OpenAI 兼容的 function calling 结构 */
export interface ToolCallFunction {
  name: string;
  arguments: string;
}

export interface ToolCall {
  id: string;
  type: string;
  function: ToolCallFunction;
}

export interface ChatMessage {
  role: string;
  content: string;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
}

/** 工具参数里单个字段的 JSON Schema 片段 */
export interface ToolParam {
  type: string;
  description: string;
  items?: ToolParam;
}

export interface ToolParameters {
  type: string;
  properties: Record<string, ToolParam>;
  required: string[];
}

export interface ToolFunctionDef {
  name: string;
  description: string;
  parameters: ToolParameters;
}

export interface ToolDef {
  type: string;
  function: ToolFunctionDef;
}

/** 工具执行结果；ok=false 时 content 是给模型看的错误说明，会被回喂 */
export interface ToolResult {
  ok: boolean;
  content: string;
}

export interface AgentTool {
  definition(): ToolDef;
  /** 异步：查词典、读文件这类工具需要 IO */
  execute(argsJson: string): Promise<ToolResult>;
}
