@tool
extends Node

## Client to interface with local Ollama API.
## Uses HTTPRequest dynamically to post JSON to /api/chat.

## Queries Ollama and returns a Dictionary:
## {
##     "success": bool,
##     "content": String (Ollama's response text),
##     "error": String (Error details if success is false)
## }
func query_ollama(base_url: String, model: String, system_prompt: String, user_prompt: String) -> Dictionary:
	var response = {
		"success": false,
		"content": "",
		"error": ""
	}
	
	# Format URL
	var url = base_url.strip_edges()
	if url.is_empty():
		response["error"] = "Ollama URL cannot be empty."
		return response
	if not url.ends_with("/"):
		url += "/"
	url += "api/chat"
	
	# Instantiate HTTPRequest dynamically
	var http_request = HTTPRequest.new()
	add_child(http_request)
	
	# Set request timeout (30 seconds)
	http_request.timeout = 30.0
	
	var messages = [
		{
			"role": "system",
			"content": system_prompt
		},
		{
			"role": "user",
			"content": user_prompt
		}
	]
	
	var payload = {
		"model": model,
		"messages": messages,
		"stream": false,
		"format": "json" # Forces the Ollama model to respond in JSON mode
	}
	
	var headers = [
		"Content-Type: application/json"
	]
	
	var json_payload = JSON.stringify(payload)
	
	# Initiate POST request
	var err = http_request.request(url, headers, HTTPClient.METHOD_POST, json_payload)
	if err != OK:
		response["error"] = "Failed to start HTTP request. Error code: %d" % err
		http_request.queue_free()
		return response
	
	# Wait for completion
	var result = await http_request.request_completed
	var req_result = result[0]
	var response_code = result[1]
	var response_headers = result[2]
	var body_bytes = result[3]
	
	# Clean up HTTPRequest node
	http_request.queue_free()
	
	# 1. Check HTTPRequest completion result
	if req_result != HTTPRequest.RESULT_SUCCESS:
		response["error"] = "HTTP request failed. Result code: %d" % req_result
		return response
		
	# 2. Check HTTP status code
	if response_code != 200:
		var err_body = body_bytes.get_string_from_utf8()
		response["error"] = "Ollama API returned non-200 status code: %d. Response: %s" % [response_code, err_body]
		return response
		
	# 3. Parse JSON response from Ollama
	var body_str = body_bytes.get_string_from_utf8()
	var json = JSON.new()
	var parse_err = json.parse(body_str)
	if parse_err != OK:
		response["error"] = "Failed to parse Ollama API JSON response. Error: %s" % json.get_error_message()
		return response
		
	var data = json.get_data()
	if not data is Dictionary:
		response["error"] = "Ollama response JSON was not a Dictionary."
		return response
		
	# 4. Extract message and content from Ollama response
	if not data.has("message") or not data["message"] is Dictionary or not data["message"].has("content"):
		response["error"] = "Ollama response JSON missing 'message' or 'message.content'."
		return response
		
	var content = data["message"]["content"]
	response["success"] = true
	response["content"] = content
	
	return response
