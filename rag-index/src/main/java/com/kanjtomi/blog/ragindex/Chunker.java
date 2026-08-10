package com.kanjtomi.blog.ragindex;

import java.util.ArrayList;
import java.util.List;

/**
 * Splits a post body into embeddable chunks: first by "## " headings (each
 * heading + its content becomes one chunk), then any chunk still longer than
 * MAX_CHARS is further cut into overlapping fixed-size windows.
 */
public class Chunker {

    private static final int MAX_CHARS = 1500;
    private static final int OVERLAP_CHARS = 200;

    public static List<String> chunk(String body) {
        List<String> sections = splitByHeading(body);
        List<String> chunks = new ArrayList<>();
        for (String section : sections) {
            String trimmed = section.strip();
            if (trimmed.isEmpty()) continue;
            if (trimmed.length() <= MAX_CHARS) {
                chunks.add(trimmed);
            } else {
                chunks.addAll(slidingWindow(trimmed));
            }
        }
        return chunks;
    }

    private static List<String> splitByHeading(String body) {
        List<String> sections = new ArrayList<>();
        StringBuilder current = new StringBuilder();
        for (String line : body.split("\\R")) {
            if (line.startsWith("## ") && current.length() > 0) {
                sections.add(current.toString());
                current = new StringBuilder();
            }
            current.append(line).append('\n');
        }
        if (current.length() > 0) {
            sections.add(current.toString());
        }
        return sections.isEmpty() ? List.of(body) : sections;
    }

    private static List<String> slidingWindow(String text) {
        List<String> windows = new ArrayList<>();
        int start = 0;
        int step = MAX_CHARS - OVERLAP_CHARS;
        while (start < text.length()) {
            int end = Math.min(start + MAX_CHARS, text.length());
            windows.add(text.substring(start, end).strip());
            if (end == text.length()) break;
            start += step;
        }
        return windows;
    }
}
