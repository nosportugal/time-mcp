#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <json-c/json.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t server = -1;
static int input_fd = -1;
static int output_fd = -1;
static const char *test_name = "startup";

static void timeout_handler(int signal_number)
{
    (void)signal_number;
    static const char message[] = "FAIL: overall protocol test timeout\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    if (server > 0) kill(server, SIGKILL);
    _exit(EXIT_FAILURE);
}

static void cleanup(void)
{
    if (input_fd >= 0) close(input_fd);
    if (output_fd >= 0) close(output_fd);
    if (server > 0) {
        kill(server, SIGKILL);
        while (waitpid(server, NULL, 0) < 0 && errno == EINTR) {}
    }
}

static void require(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL [%s]: %s\n", test_name, message);
        exit(EXIT_FAILURE);
    }
}

static void start_server(const char *binary)
{
    int to_server[2], from_server[2];
    require(pipe(to_server) == 0, "stdin pipe");
    require(pipe(from_server) == 0, "stdout pipe");
    server = fork();
    require(server >= 0, "fork");
    if (server == 0) {
        if (dup2(to_server[0], STDIN_FILENO) < 0 ||
            dup2(from_server[1], STDOUT_FILENO) < 0) _exit(126);
        close(to_server[0]);
        close(to_server[1]);
        close(from_server[0]);
        close(from_server[1]);
        execl(binary, binary, (char *)NULL);
        perror(binary);
        _exit(127);
    }
    close(to_server[0]);
    close(from_server[1]);
    input_fd = to_server[1];
    output_fd = from_server[0];
}

static void send_request(const char *request)
{
    size_t remaining = strlen(request);
    while (remaining > 0) {
        ssize_t written = write(input_fd, request, remaining);
        if (written < 0 && errno == EINTR) continue;
        require(written > 0, "write request");
        request += written;
        remaining -= (size_t)written;
    }
}

static struct json_object *receive_response(void)
{
    char line[8192];
    size_t length = 0;
    for (;;) {
        struct pollfd descriptor = {output_fd, POLLIN, 0};
        int ready = poll(&descriptor, 1, 2000);
        if (ready < 0 && errno == EINTR) continue;
        require(ready > 0, "response timeout");
        require(length < sizeof(line) - 1, "response too large");
        ssize_t received = read(output_fd, line + length, 1);
        if (received < 0 && errno == EINTR) continue;
        require(received == 1, "unexpected EOF");
        if (line[length++] == '\n') break;
    }
    line[length] = '\0';
    struct json_tokener *parser = json_tokener_new();
    require(parser != NULL, "JSON parser allocation");
    json_tokener_set_flags(parser, JSON_TOKENER_STRICT);
    struct json_object *response = json_tokener_parse_ex(parser, line, (int)length);
    require(json_tokener_get_error(parser) == json_tokener_success &&
            json_tokener_get_parse_end(parser) == length, "invalid JSON response");
    json_tokener_free(parser);
    require(json_object_is_type(response, json_type_object), "response is not an object");
    return response;
}

static struct json_object *member(struct json_object *object, const char *key,
                                  enum json_type type)
{
    struct json_object *value = NULL;
    require(json_object_object_get_ex(object, key, &value), key);
    require(json_object_is_type(value, type), "wrong JSON member type");
    return value;
}

static void expect_string(struct json_object *object, const char *key, const char *expected)
{
    struct json_object *value = member(object, key, json_type_string);
    require((size_t)json_object_get_string_len(value) == strlen(expected) &&
            strcmp(json_object_get_string(value), expected) == 0, key);
}

static struct json_object *envelope(struct json_object *response, const char *id)
{
    expect_string(response, "jsonrpc", "2.0");
    struct json_object *actual_id = NULL;
    require(json_object_object_get_ex(response, "id", &actual_id), "missing id");
    struct json_object *expected_id = json_tokener_parse(id);
    require(json_object_equal(actual_id, expected_id), "response id mismatch");
    json_object_put(expected_id);
    require(json_object_object_length(response) == 3, "unexpected envelope fields");
    return member(response, "result", json_type_object);
}

static void expect_empty(const char *id)
{
    struct json_object *response = receive_response();
    require(json_object_object_length(envelope(response, id)) == 0, "expected empty result");
    json_object_put(response);
}

static void expect_silence(void)
{
    struct pollfd descriptor = {output_fd, POLLIN, 0};
    require(poll(&descriptor, 1, 100) == 0, "notification produced output or closed stdout");
}

static void finish_server(void)
{
    if (input_fd >= 0) close(input_fd);
    input_fd = -1;
    struct pollfd descriptor = {output_fd, POLLIN, 0};
    require(poll(&descriptor, 1, 2000) > 0, "EOF shutdown timeout");
    char extra;
    require(read(output_fd, &extra, 1) == 0, "unexpected extra output");
    int exit_status;
    require(waitpid(server, &exit_status, 0) == server, "waitpid");
    server = -1;
    require(WIFEXITED(exit_status) && WEXITSTATUS(exit_status) == 0, "server exited unsuccessfully");
    close(output_fd);
    output_fd = -1;
}

int main(int argc, char **argv)
{
    require(argc == 2, "usage: tests/test_mcp ./server-binary");
    require(atexit(cleanup) == 0, "register cleanup");
    signal(SIGPIPE, SIG_IGN);
    struct sigaction timeout_action = {0};
    timeout_action.sa_handler = timeout_handler;
    sigemptyset(&timeout_action.sa_mask);
    require(sigaction(SIGALRM, &timeout_action, NULL) == 0, "register timeout handler");
    alarm(20);
    start_server(argv[1]);

    test_name = "initialize with integer id";
    send_request("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"c-tests\",\"version\":\"1\"}}}\n");
    struct json_object *response = receive_response();
    struct json_object *result = envelope(response, "1");
    expect_string(result, "protocolVersion", "2024-11-05");
    member(member(result, "capabilities", json_type_object), "tools", json_type_object);
    struct json_object *info = member(result, "serverInfo", json_type_object);
    member(info, "name", json_type_string);
    member(info, "version", json_type_string);
    json_object_put(response);
    puts("PASS initialize");

    test_name = "notification silence";
    send_request("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n");
    expect_silence();

    test_name = "tools/list with whitespace and multi-digit id";
    send_request("{ \"jsonrpc\": \"2.0\", \"id\" : 42, \"method\" : \"tools/list\", \"params\": {} }\n");
    response = receive_response();
    result = envelope(response, "42");
    struct json_object *tools = member(result, "tools", json_type_array);
    require(json_object_array_length(tools) == 1, "expected one tool");
    struct json_object *tool = json_object_array_get_idx(tools, 0);
    expect_string(tool, "name", "date");
    expect_string(member(tool, "inputSchema", json_type_object), "type", "object");
    json_object_put(response);
    puts("PASS notification silence and tools/list schema");

    test_name = "tools/call with string id and current UTC date";
    time_t before = time(NULL);
    send_request("{\"jsonrpc\":\"2.0\",\"id\":\"req-uuid-99\",\"method\":\"tools/call\",\"params\":{\"name\":\"date\",\"arguments\":{}}}\n");
    response = receive_response();
    time_t after = time(NULL);
    result = envelope(response, "\"req-uuid-99\"");
    struct json_object *content = member(result, "content", json_type_array);
    require(json_object_array_length(content) == 1, "expected one content item");
    struct json_object *item = json_object_array_get_idx(content, 0);
    expect_string(item, "type", "text");
    struct json_object *text = member(item, "text", json_type_string);
    const char *timestamp = json_object_get_string(text);
    require(json_object_get_string_len(text) == 29, "invalid timestamp length");
    require(before != (time_t)-1 && after >= before && after - before <= 5, "invalid test clock interval");
    int matches = 0;
    for (time_t instant = before; instant <= after; ++instant) {
        char expected[64];
        struct tm utc;
        require(gmtime_r(&instant, &utc) != NULL, "UTC conversion");
        require(strftime(expected, sizeof(expected), "%Y-%m-%d %H:%M:%S UTC (%a)", &utc) > 0, "date formatting");
        if (strcmp(timestamp, expected) == 0) matches = 1;
    }
    require(matches, "timestamp must match a UTC second between request and response, including weekday");
    json_object_put(response);
    puts("PASS tools/call UTC timestamp and weekday");

    test_name = "pipelined notification, ping, and unknown method";
    send_request("{\"method\":\"notifications/initialized\"}\n"
                 "{\"id\":0,\"method\":\"ping\"}\n"
                 "{\"id\":-99,\"method\":\"resources/list\"}\n");
    expect_empty("0");
    expect_empty("-99");
    puts("PASS pipelined requests, ping, unknown method, zero and negative ids");

    test_name = "EOF without trailing newline";
    send_request("{\"id\":\"eof\",\"method\":\"ping\"}");
    close(input_fd);
    input_fd = -1;
    expect_empty("\"eof\"");
    finish_server();
    puts("PASS EOF without trailing newline and clean shutdown");

    test_name = "empty stdin";
    start_server(argv[1]);
    finish_server();
    puts("PASS empty stdin");
    puts("All protocol tests passed.");
    return EXIT_SUCCESS;
}