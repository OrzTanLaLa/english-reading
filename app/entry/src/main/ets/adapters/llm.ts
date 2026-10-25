/**
 * DeepSeek（OpenAI 兼容）聊天补全客户端：只做一件事，发一轮 messages + tools，拿回一条 assistant 消息。
 * 解析 tool_calls 是本批次（B1.5）要验证的核心。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ChatMessage, ToolCall, ToolDef } from '../core/contracts';

interface LlmRequestBody {
  model: string;
  messages: ChatMessage[];
  tools: ToolDef[];
  temperature: number;
  response_format?: ResponseFormat;
}

/** DeepSeek JSON Output：{'type':'json_object'} 保证输出合法 JSON（官方指南） */
interface ResponseFormat {
  type: string;
}

interface LlmResponseMessage {
  role: string;
  content: string | null;
  tool_calls?: ToolCall[];
  reasoning_content?: string;
}

interface LlmChoice {
  message: LlmResponseMessage;
  finish_reason: string;
}

interface LlmResponse {
  choices: LlmChoice[];
}

interface LlmErrorBody {
  error: LlmErrorDetail;
}

interface LlmErrorDetail {
  message: string;
  type: string;
}

export class DeepSeekClient {
  private apiKey: string;
  private model: string;

  constructor(apiKey: string, model: string = 'deepseek-chat') {
    this.apiKey = apiKey;
    this.model = model;
  }

  /**
   * 发一轮请求，返回 assistant 消息（可能是纯文本，也可能带 tool_calls）。
   * @param jsonMode true 时带 response_format=json_object，要求输出合法 JSON
   */
  async complete(messages: ChatMessage[], tools: ToolDef[], jsonMode: boolean = false): Promise<ChatMessage> {
    const body: LlmRequestBody = {
      model: this.model,
      messages: messages,
      tools: tools,
      temperature: 0
    };
    if (jsonMode) {
      body.response_format = { type: 'json_object' };
    }

    const request = http.createHttp();
    try {
      const response = await request.request('https://api.deepseek.com/chat/completions', {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.apiKey
        },
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 90000
      });

      const text: string = response.result as string;
      if (response.responseCode !== 200) {
        throw new Error('HTTP ' + response.responseCode + ': ' + text);
      }

      const parsed: LlmResponse = JSON.parse(text) as LlmResponse;
      if (parsed.choices.length === 0) {
        throw new Error('模型没有返回 choices');
      }

      const m: LlmResponseMessage = parsed.choices[0].message;
      const result: ChatMessage = {
        role: 'assistant',
        content: m.content === null ? '' : m.content
      };
      if (m.tool_calls !== undefined && m.tool_calls.length > 0) {
        result.tool_calls = m.tool_calls;
      }
      return result;
    } catch (err) {
      const e = err as BusinessError;
      const msg: string = e.message === undefined ? String(err) : e.message;
      throw new Error('请求失败: ' + msg);
    } finally {
      request.destroy();
    }
  }
}
