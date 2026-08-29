# --- Origin Access Control for the main site bucket ---
resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.site_subdomain}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# --- CloudFront Function: rewrites directory-style URIs to their index.html ---
# S3 (via OAC) only auto-resolves index.html for the exact root "/" request
# (via default_root_object). For any other path — e.g. /posts/test-post/ —
# CloudFront requests the literal key "posts/test-post/", which doesn't
# exist (the real object is "posts/test-post/index.html"), and the private
# bucket returns 403 AccessDenied instead of a clean 404. This function
# rewrites the request at the edge before it reaches the origin.
resource "aws_cloudfront_function" "url_rewrite" {
  name    = "hugo-directory-index-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Append index.html to directory-style requests"
  publish = true
  code    = <<-EOT
    function handler(event) {
        var request = event.request;
        var uri = request.uri;

        if (uri.endsWith('/')) {
            request.uri += 'index.html';
        } else if (!uri.includes('.')) {
            request.uri += '/index.html';
        }

        return request;
    }
  EOT
}

# --- Main site distribution: serves www.kanjtomi1967.net from S3 (private, via OAC) ---
resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [var.site_subdomain]
  price_class         = "PriceClass_200" # skip most-expensive edge locations; adjust if needed

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-site-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  # Photo-upload feature (photos.tf): objects live at S3 key "photos/..."
  # and are served at the matching URL path "/photos/...", so no origin_path
  # stripping is needed.
  origin {
    domain_name              = aws_s3_bucket.photos.bucket_regional_domain_name
    origin_id                = "s3-photos-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-site-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS managed "CachingOptimized"

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.url_rewrite.arn
    }
  }

  # Uploaded photos are individual objects (not directory-style paths), so
  # this behavior skips the url_rewrite function entirely.
  ordered_cache_behavior {
    path_pattern           = "/photos/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-photos-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS managed "CachingOptimized"
  }

  # SPA/Hugo-style 404 handling: Hugo generates its own 404.html
  custom_error_response {
    error_code         = 404
    response_code      = 404
    response_page_path = "/404.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# --- CloudFront Function: redirects every request to https://www.<domain><uri> ---
# Runs at the edge on viewer-request, before any origin fetch — so the apex
# distribution below never actually needs to reach S3, and no public bucket
# or website-hosting config is required.
resource "aws_cloudfront_function" "apex_redirect" {
  name    = "apex-to-www-redirect"
  runtime = "cloudfront-js-2.0"
  comment = "Redirect ${var.domain_name} -> https://${var.site_subdomain}"
  publish = true
  code    = <<-EOT
    function handler(event) {
        var request = event.request;
        return {
            statusCode: 301,
            statusDescription: "Moved Permanently",
            headers: {
                "location": { value: "https://${var.site_subdomain}" + request.uri }
            }
        };
    }
  EOT
}

# --- Apex redirect distribution: every request is redirected at the edge ---
# The origin below is required by CloudFront's schema but is never actually
# fetched from, since the function returns a response before origin lookup.
# We point it at the same private site bucket (already has an OAC policy).
resource "aws_cloudfront_distribution" "apex_redirect" {
  enabled         = true
  is_ipv6_enabled = true
  aliases         = [var.domain_name]
  price_class     = "PriceClass_200"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "unused-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "unused-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS managed "CachingDisabled"

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.apex_redirect.arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}
