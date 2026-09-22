package com.kanjtomi.blog.comments;

import com.amazonaws.services.lambda.runtime.ClientContext;
import com.amazonaws.services.lambda.runtime.CognitoIdentity;
import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.LambdaLogger;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Plain-HTTP adapter that lets the existing Lambda {@link Handler} run outside AWS Lambda
 * (e.g. as a container in Kubernetes), for k8s learning/staging purposes.
 *
 * It does NOT modify or replace the Lambda deployment: {@link Handler} is still the entry
 * point Terraform deploys as the real AWS Lambda function. This class only translates a
 * plain HTTP request into the same {@link APIGatewayV2HTTPEvent} shape API Gateway would
 * build, and calls the exact same handler code, so business logic is never duplicated.
 *
 * Not part of the production deployment path (Terraform packages the shaded jar and points
 * Lambda at {@code Handler::handleRequest} directly; this class is only invoked by the
 * container entrypoint used in {@code lambda-comments/k8s/}).
 */
public class HttpAdapter {

    public static void main(String[] args) throws IOException {
        int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "8080"));
        Handler handler = new Handler();
        Context context = new SimpleContext();

        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/health", exchange -> writeResponse(exchange, 200, "ok"));
        server.createContext("/", exchange -> handle(exchange, handler, context));
        server.setExecutor(null);
        server.start();
        System.out.println("comments HTTP adapter listening on :" + port);
    }

    private static void handle(HttpExchange exchange, Handler handler, Context context) {
        try {
            APIGatewayV2HTTPEvent event = toEvent(exchange);
            APIGatewayV2HTTPResponse response = handler.handleRequest(event, context);
            writeResponse(exchange, response);
        } catch (Exception e) {
            e.printStackTrace();
            try {
                writeResponse(exchange, 500, "{\"error\":\"internal server error\"}");
            } catch (IOException ignored) {
                // best-effort; connection may already be broken
            }
        } finally {
            exchange.close();
        }
    }

    private static APIGatewayV2HTTPEvent toEvent(HttpExchange exchange) throws IOException {
        String method = exchange.getRequestMethod();
        String path = exchange.getRequestURI().getPath();

        APIGatewayV2HTTPEvent event = new APIGatewayV2HTTPEvent();
        event.setRouteKey(method + " " + path);
        event.setRawPath(path);

        Map<String, String> headers = new HashMap<>();
        exchange.getRequestHeaders().forEach((name, values) -> {
            if (!values.isEmpty()) {
                headers.put(name.toLowerCase(), values.get(0));
            }
        });
        event.setHeaders(headers);
        event.setQueryStringParameters(parseQuery(exchange.getRequestURI().getRawQuery()));

        try (InputStream in = exchange.getRequestBody()) {
            byte[] bodyBytes = in.readAllBytes();
            event.setBody(bodyBytes.length == 0 ? null : new String(bodyBytes, StandardCharsets.UTF_8));
        }

        APIGatewayV2HTTPEvent.RequestContext.Http http = new APIGatewayV2HTTPEvent.RequestContext.Http();
        http.setMethod(method);
        http.setPath(path);
        String sourceIp = exchange.getRemoteAddress() == null || exchange.getRemoteAddress().getAddress() == null
                ? null
                : exchange.getRemoteAddress().getAddress().getHostAddress();
        http.setSourceIp(sourceIp);

        APIGatewayV2HTTPEvent.RequestContext requestContext = new APIGatewayV2HTTPEvent.RequestContext();
        requestContext.setHttp(http);
        requestContext.setRouteKey(event.getRouteKey());
        event.setRequestContext(requestContext);

        return event;
    }

    private static Map<String, String> parseQuery(String rawQuery) {
        Map<String, String> params = new HashMap<>();
        if (rawQuery == null || rawQuery.isBlank()) {
            return params;
        }
        for (String pair : rawQuery.split("&")) {
            if (pair.isBlank()) continue;
            int eq = pair.indexOf('=');
            String key = eq >= 0 ? pair.substring(0, eq) : pair;
            String value = eq >= 0 ? pair.substring(eq + 1) : "";
            params.put(
                    URLDecoder.decode(key, StandardCharsets.UTF_8),
                    URLDecoder.decode(value, StandardCharsets.UTF_8)
            );
        }
        return params;
    }

    private static void writeResponse(HttpExchange exchange, APIGatewayV2HTTPResponse response) throws IOException {
        Map<String, String> headers = response.getHeaders();
        if (headers != null) {
            headers.forEach((k, v) -> exchange.getResponseHeaders().set(k, v));
        }
        writeResponse(exchange, response.getStatusCode(), response.getBody() == null ? "" : response.getBody());
    }

    private static void writeResponse(HttpExchange exchange, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().putIfAbsent("Content-Type", List.of("application/json; charset=utf-8"));
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    /** Minimal no-op {@link Context}, enough for {@link Handler}'s error logging. */
    private static class SimpleContext implements Context {
        @Override public String getAwsRequestId() { return "local"; }
        @Override public String getLogGroupName() { return "local"; }
        @Override public String getLogStreamName() { return "local"; }
        @Override public String getFunctionName() { return "comments-http-adapter"; }
        @Override public String getFunctionVersion() { return "local"; }
        @Override public String getInvokedFunctionArn() { return "local"; }
        @Override public CognitoIdentity getIdentity() { return null; }
        @Override public ClientContext getClientContext() { return null; }
        @Override public int getRemainingTimeInMillis() { return Integer.MAX_VALUE; }
        @Override public int getMemoryLimitInMB() { return 512; }
        @Override public LambdaLogger getLogger() {
            return new LambdaLogger() {
                @Override public void log(String message) { System.out.println(message); }
                @Override public void log(byte[] message) { System.out.write(message, 0, message.length); }
            };
        }
    }
}
