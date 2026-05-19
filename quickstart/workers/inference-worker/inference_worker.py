import os
from typing import Any, Dict, List

from iii import InitOptions, Logger, register_worker
from transformers import AutoModelForCausalLM, AutoTokenizer

iii = register_worker(
    os.environ.get("III_URL", "ws://localhost:49134"),
    InitOptions(worker_name="inference-worker"),
)
logger = Logger()

# 1. Install dependencies
# pip install transformers accelerate gguf torch


model_id = os.environ.get("MODEL_ID", "ggml-org/gemma-3-270m-GGUF")
gguf_file = os.environ.get("GGUF_FILE", "gemma-3-270m-Q8_0.gguf")
max_new_tokens = int(os.environ.get("MAX_NEW_TOKENS", "256"))

# 2. Load tokenizer and model from the GGUF file
tokenizer = AutoTokenizer.from_pretrained(model_id, gguf_file=gguf_file)
model = AutoModelForCausalLM.from_pretrained(model_id, gguf_file=gguf_file)

tokenizer.chat_template = ("""{{ bos_token }}
{%- if messages[0]['role'] == 'system' -%}
    {%- if messages[0]['content'] is string -%}
        {%- set first_user_prefix = messages[0]['content'] + '

' -%}
    {%- else -%}
        {%- set first_user_prefix = messages[0]['content'][0]['text'] + '

' -%}
    {%- endif -%}
    {%- set loop_messages = messages[1:] -%}
{%- else -%}
    {%- set first_user_prefix = "" -%}
    {%- set loop_messages = messages -%}
{%- endif -%}
{%- for message in loop_messages -%}
    {%- if (message['role'] == 'user') != (loop.index0 % 2 == 0) -%}
        {{ raise_exception("Conversation roles must alternate user/assistant/user/assistant/...") }}
    {%- endif -%}
    {%- if (message['role'] == 'assistant') -%}
        {%- set role = "model" -%}
    {%- else -%}
        {%- set role = message['role'] -%}
    {%- endif -%}
    {{ '<start_of_turn>' + role + '
' + (first_user_prefix if loop.first else "") }}
    {%- if message['content'] is string -%}
        {{ message['content'] | trim }}
    {%- elif message['content'] is iterable -%}
        {%- for item in message['content'] -%}
            {%- if item['type'] == 'image' -%}
                {{ '<start_of_image>' }}
            {%- elif item['type'] == 'text' -%}
                {{ item['text'] | trim }}
            {%- endif -%}
        {%- endfor -%}
    {%- else -%}
        {{ raise_exception("Invalid content type") }}
    {%- endif -%}
    {{ '<end_of_turn>
' }}
{%- endfor -%}
{%- if add_generation_prompt -%}
    {{'<start_of_turn>model
'}}
{%- endif -%}""")

# 3. Run inference
def run_inference_handler(payload: Dict[str, str | List[Dict[str, Any]]]) -> Dict[str, Any]:
    messages = payload.get("messages", [])
    if not messages:
        return {"error": "messages must contain at least one chat message"}

    text = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    inputs = tokenizer(text, return_tensors="pt").to(model.device)

    output = model.generate(**inputs, max_new_tokens=max_new_tokens)
    result = tokenizer.decode(output[0][inputs["input_ids"].shape[-1]:], skip_special_tokens=True)

    logger.info("inference::run_inference completed")

    # running_inference = iii.trigger(
    #     {
    #         "function_id": "inference::get",
    #         "payload": {"scope": "math", "key": "running_inference"},
    #     }
    # )
    # new_result = payload | {"messages": payload["messages"] + (running_inference or [])}
    # iii.trigger(
    #     {
    #         "function_id": "inference::set",
    #         "payload": {"scope": "math", "key": "running_inference", "value": new_result},
    #     }
    # )
    # result["running_inference"] = new_result
    return {"text": result}

# def add_handler(payload: dict) -> dict:
#     a = payload.get("a", 0)
#     b = payload.get("b", 0)
#     logger.info(f"math::add called in Python with a={a}, b={b}")
#     result = {"c": a + b}

#     # --- Uncomment after: iii worker add iii-state ---
#     running_total = iii.trigger(
#         {
#             "function_id": "state::get",
#             "payload": {"scope": "math", "key": "running_total"},
#         }
#     )
#     new_total = (running_total or 0) + result["c"]
#     iii.trigger(
#         {
#             "function_id": "state::set",
#             "payload": {"scope": "math", "key": "running_total", "value": new_total},
#         }
#     )
#     result["running_total"] = new_total

#     return result


# iii.register_function("math::add", add_handler)
iii.register_function("inference::run_inference", run_inference_handler)

print("Inference worker started - listening for calls")
