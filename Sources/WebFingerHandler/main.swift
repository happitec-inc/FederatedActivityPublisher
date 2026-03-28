import AWSLambdaEvents
import AWSLambdaRuntime

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    let resource = event.queryStringParameters?["resource"]

    guard let resource else {
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing required query parameter: resource"}"#
        )
    }

    guard resource == "acct:test@activity.happitec.com" else {
        return APIGatewayResponse(
            statusCode: .notFound,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Resource not found"}"#
        )
    }

    let body = """
    {
      "subject": "acct:test@activity.happitec.com",
      "links": [
        {
          "rel": "self",
          "type": "application/activity+json",
          "href": "https://activity.happitec.com/users/test"
        }
      ]
    }
    """

    return APIGatewayResponse(
        statusCode: .ok,
        headers: ["content-type": "application/jrd+json"],
        body: body
    )
}

try await runtime.run()
