import { webcrypto } from 'node:crypto';
import { Logger, registerWorker } from 'iii-sdk';

if (!globalThis.crypto) {
  Object.defineProperty(globalThis, 'crypto', {
    value: webcrypto,
  });
}

const iii = registerWorker(process.env.III_URL ?? 'ws://localhost:49134');
const logger = new Logger();

type ChatMessage = {
  role: 'system' | 'user' | 'assistant';
  content: string;
};

type InferenceRequest = {
  messages: ChatMessage[];
  [key: string]: unknown;
};

type InferenceResponse = {
  text?: string;
  error?: string;
};

iii.registerFunction(
  'inference::get_response',
  async (payload: InferenceRequest) => {
    logger.info('inference::get_response called in TypeScript', payload);

    const result = (await iii.trigger({
      function_id: 'inference::run_inference',
      payload,
    })) as InferenceResponse;

    return {
      id: `chatcmpl-${Date.now()}`,
      object: 'chat.completion',
      model: process.env.MODEL_ID ?? 'ggml-org/gemma-3-270m-GGUF',
      choices: [
        {
          index: 0,
          message: {
            role: 'assistant',
            content: result.text ?? '',
          },
          finish_reason: result.error ? 'error' : 'stop',
        },
      ],
      error: result.error,
    };
  },
);

iii.registerFunction(
  'http::run_inference_over_http',
  async (payload: { body: InferenceRequest }) => {
    if (!Array.isArray(payload.body?.messages)) {
      return {
        status_code: 400,
        body: { error: 'request body must include messages: ChatMessage[]' },
        headers: { 'Content-Type': 'application/json' },
      };
    }

    const result = await iii.trigger({
      function_id: 'inference::get_response',
      payload: payload.body,
    });

    logger.info('Running http inference');
    return {
      status_code: 200,
      body: result,
      headers: { 'Content-Type': 'application/json' },
    };
  },
);

iii.registerTrigger({
  type: 'http',
  function_id: 'http::run_inference_over_http',
  config: { api_path: '/v1/chat/completions', http_method: 'POST' },
});

logger.info('Caller worker started - listening for calls');
