package com.kanjtomi.blog.ragindex;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Minimal front-matter reader for Hugo posts. Only extracts the handful of
 * fields the indexer needs (title, draft) — not a general YAML parser.
 */
public class PostParser {

    private static final Pattern TITLE_PATTERN = Pattern.compile("^title:\\s*\"?(.*?)\"?\\s*$");
    private static final Pattern DRAFT_PATTERN = Pattern.compile("^draft:\\s*(true|false)\\s*$");

    public static Post parse(Path file) throws IOException {
        String content = Files.readString(file);
        String nameWithoutExt = stripExtension(file.getFileName().toString());

        // Hugo multilingual filenames carry a language suffix, e.g.
        // "hello-world.ja.md" / "hello-world.en.md". Strip it to recover the
        // shared slug, and use it to build the language-prefixed URL
        // (defaultContentLanguageInSubdir = true in config.toml).
        String lang = "ja";
        String slug = nameWithoutExt;
        int langDot = nameWithoutExt.lastIndexOf('.');
        if (langDot != -1) {
            String suffix = nameWithoutExt.substring(langDot + 1);
            if (suffix.equals("ja") || suffix.equals("en")) {
                lang = suffix;
                slug = nameWithoutExt.substring(0, langDot);
            }
        }
        String url = "/" + lang + "/posts/" + slug + "/";

        String title = slug;
        boolean draft = false;
        String body = content;

        if (content.startsWith("---")) {
            int end = content.indexOf("\n---", 3);
            if (end != -1) {
                String frontMatter = content.substring(3, end);
                body = content.substring(end + 4).stripLeading();

                for (String line : frontMatter.split("\\R")) {
                    Matcher titleMatcher = TITLE_PATTERN.matcher(line);
                    if (titleMatcher.matches()) {
                        title = titleMatcher.group(1);
                        continue;
                    }
                    Matcher draftMatcher = DRAFT_PATTERN.matcher(line);
                    if (draftMatcher.matches()) {
                        draft = Boolean.parseBoolean(draftMatcher.group(1));
                    }
                }
            }
        }

        return new Post(slug, title, url, body, draft);
    }

    private static String stripExtension(String filename) {
        int dot = filename.lastIndexOf('.');
        return dot == -1 ? filename : filename.substring(0, dot);
    }
}
