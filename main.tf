provider "aws" {
}

# S3 bucket

resource "aws_s3_bucket" "bucket" {
	force_destroy = "true"
}

resource "aws_s3_bucket" "bucket_cors" {
	force_destroy = "true"
  cors_rule {
    allowed_methods = ["GET"]
    allowed_origins = ["*"]
  }
}

resource "aws_s3_bucket" "bucket_cors_null" {
	force_destroy = "true"
  cors_rule {
    allowed_methods = ["GET"]
    allowed_origins = ["null"]
  }
}

# Lambda function

resource "random_id" "id" {
  byte_length = 8
}

data "archive_file" "lambda_zip" {
	type = "zip"
	output_path = "/tmp/${random_id.id.hex}-lambda.zip"
  source {
    content  = <<EOF
const AWS = require("aws-sdk");

const s3 = new AWS.S3({
	signatureVersion: "v4",
});

module.exports.handler = async (event, context) => {
	const filename = event.path.match(/^.*\/(?<file>.*?)$/).groups.file;

	const {redirect, cors, corsCredentials, bucket} = (event.queryStringParameters || {});

	const params = {
		Bucket: bucket === "cors" ? process.env.BUCKET_CORS : bucket === "cors_null" ? process.env.BUCKET_CORS_NULL : process.env.BUCKET,
		Key: filename,
	};

	const signedUrl = await s3.getSignedUrlPromise("getObject", params);

	const corsHeaders = (() => {
		if (cors) {
			if (!corsCredentials) {
				return {"Access-Control-Allow-Origin": "*"}
			}else {
				const headers = event.headers;
				const origin = headers.origin || headers.Origin;

				return {
					"Access-Control-Allow-Origin": origin,
					"Access-Control-Allow-Credentials": "true",
					"Vary": "Origin", // for proxies
				};
			}
		}
	})();

	if (redirect) {
		return {
			statusCode: 303,
			headers: {
				Location: signedUrl,
				...corsHeaders,
			}
		}
	}

	return {
		statusCode: 200,
		headers: {
			...corsHeaders,
		},
		body: signedUrl,
	};
};
EOF
    filename = "backend.js"
  }
}

resource "aws_lambda_function" "signer_lambda" {
	function_name = "signer-${random_id.id.hex}-function"

  filename = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler = "backend.handler"
  runtime = "nodejs12.x"
  role = aws_iam_role.lambda_exec.arn
	environment {
		variables = {
			BUCKET = aws_s3_bucket.bucket.bucket
			BUCKET_CORS = aws_s3_bucket.bucket_cors.bucket
			BUCKET_CORS_NULL = aws_s3_bucket.bucket_cors_null.bucket
		}
	}
}

data "aws_iam_policy_document" "lambda_exec_role_policy" {
	statement {
		actions = [
			"s3:GetObject",
		]
		resources = [
			"${aws_s3_bucket.bucket.arn}/*",
			"${aws_s3_bucket.bucket_cors.arn}/*",
			"${aws_s3_bucket.bucket_cors_null.arn}/*"
		]
	}
	statement {
		actions = [
			"logs:CreateLogGroup",
			"logs:CreateLogStream",
			"logs:PutLogEvents"
		]
		resources = [
			"arn:aws:logs:*:*:*"
		]
	}
}

resource "aws_iam_role_policy" "lambda_exec_role" {
	role = aws_iam_role.lambda_exec.id
	policy = data.aws_iam_policy_document.lambda_exec_role_policy.json
}

resource "aws_iam_role" "lambda_exec" {
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
	{
	  "Action": "sts:AssumeRole",
	  "Principal": {
		"Service": "lambda.amazonaws.com"
	  },
	  "Effect": "Allow"
	}
  ]
}
EOF
}

# sample data

resource "aws_s3_bucket_object" "object" {
  key    = "file.html"
	content = "Hello world!"
  bucket = aws_s3_bucket.bucket.bucket

	# open in the browser
	content_disposition = "inline"
	content_type = "text/html"
}

resource "aws_s3_bucket_object" "object_cors" {
  key    = "file.html"
	content = "Hello world!"
  bucket = aws_s3_bucket.bucket_cors.bucket

	# open in the browser
	content_disposition = "inline"
	content_type = "text/html"
}

resource "aws_s3_bucket_object" "object_cors_null" {
  key    = "file.html"
	content = "Hello world!"
  bucket = aws_s3_bucket.bucket_cors_null.bucket

	# open in the browser
	content_disposition = "inline"
	content_type = "text/html"
}

# API Gateway

resource "aws_api_gateway_rest_api" "rest_api" {
	name = "signer-${random_id.id.hex}-rest-api"
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_method.proxy.resource_id
  http_method = aws_api_gateway_method.proxy.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.signer_lambda.invoke_arn
}

resource "aws_api_gateway_method" "proxy_root" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_root" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_method.proxy_root.resource_id
  http_method = aws_api_gateway_method.proxy_root.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.signer_lambda.invoke_arn
}

resource "aws_api_gateway_deployment" "deployment" {
  depends_on = [
    aws_api_gateway_integration.lambda,
    aws_api_gateway_integration.lambda_root,
  ]

  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  stage_name  = "sign"
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.signer_lambda.arn
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_deployment.deployment.execution_arn}/*/*"
}

# Frontend bucket

resource "aws_s3_bucket" "frontend_bucket" {
	force_destroy = "true"
}

resource "aws_s3_bucket_policy" "default" {
  bucket = aws_s3_bucket.frontend_bucket.id
  policy = data.aws_iam_policy_document.default.json
}

resource "aws_cloudfront_origin_access_identity" "OAI" {
}

data "aws_iam_policy_document" "default" {
  statement {
    actions = ["s3:GetObject"]

    resources = ["${aws_s3_bucket.frontend_bucket.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.OAI.iam_arn]
    }
  }
}

# Insert the backend URL into the HTML
data "template_file" "index" {
  template = file("${path.module}/index.html")
  vars = {
    backend_url = aws_api_gateway_deployment.deployment.invoke_url
  }
}

resource "aws_s3_bucket_object" "frontend_object_index_html" {
  key    = "index.html"
	content = data.template_file.index.rendered
  bucket = aws_s3_bucket.frontend_bucket.bucket
  etag = md5(data.template_file.index.rendered)
	content_type = "text/html"
}

resource "aws_cloudfront_distribution" "distribution" {
  origin {
    domain_name = aws_s3_bucket.frontend_bucket.bucket_regional_domain_name
    origin_id   = "s3"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.OAI.cloudfront_access_identity_path
    }
  }
  origin {
    domain_name = replace(aws_api_gateway_deployment.deployment.invoke_url, "/^https?://([^/]*).*/", "$1")
    origin_id   = "apigw"
		origin_path = "/sign"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3"

    default_ttl = 0
    min_ttl     = 0
    max_ttl     = 0

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
  }

  ordered_cache_behavior {
    path_pattern     = "/api/*"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "apigw"

    default_ttl = 0
    min_ttl     = 0
    max_ttl     = 0

    forwarded_values {
      query_string = true
      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "frontend_url" {
	value = aws_cloudfront_distribution.distribution.domain_name
}
