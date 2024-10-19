import ballerina/http;
import ballerina/jwt;
import ballerina/log;
import ballerina/mime;
import ballerina/sql;
import ballerinax/aws.s3;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;

listener http:Listener httpListener = new (8080);

// Supabase DB connection config
configurable string host = ?;
configurable int port = ?;
configurable string username = ?;
configurable string password = ?;
configurable string databaseName = ?;

configurable string AWS_ACCESS_KEY_ID = ?;
configurable string AWS_SECRET_ACCESS_KEY = ?;
configurable string AWS_REGION = ?;
configurable string AWS_BUCKET = ?;

s3:ConnectionConfig amazonS3Config = {
    accessKeyId: AWS_ACCESS_KEY_ID,
    secretAccessKey: AWS_SECRET_ACCESS_KEY,
    region: AWS_REGION
};

s3:Client amazonS3Client = check new (amazonS3Config);

service / on httpListener {

    resource function get .() returns string {
        return "Welcome to Eventure!";
    }

}

configurable string signingSecret = ?;

http:JwtValidatorConfig config = {
    issuer: "eventure",
    audience: ["authenticated"],
    signatureConfig: {
        secret: signingSecret
    }
};

http:ListenerJwtAuthHandler jwtHandler = new (config);

// Function to authenticate and return the JWT payload
public function authenticateJWT(string authorizationHeader) returns jwt:Payload|http:Unauthorized {
    jwt:Payload|http:Unauthorized authResult = jwtHandler.authenticate(authorizationHeader);
    return authResult;
}

// Function to authorize based on a role
public function authorizeJWT(jwt:Payload payload, string role) returns http:Forbidden? {
    return jwtHandler.authorize(payload, role);
}

@http:ServiceConfig {
    cors: {
        allowOrigins: ["http://localhost:3000"],
        allowMethods: ["GET", "PUT", "POST", "DELETE", "OPTIONS"],
        allowHeaders: ["Authorization", "Content-Type"],
        allowCredentials: true
    }
}
service /auth on httpListener {

    final postgresql:Client dbClient;

    public function init() returns error? {
        self.dbClient = check new (host, username, password, databaseName, port);
        log:printInfo("Successfully connected to the database.");
    }

    resource function get anon(http:Caller caller, http:Request req) returns error? {
        check caller->respond("This is a public endpoint. No authentication required.");
    }

    resource function post validate(http:Caller caller, http:Request req) returns error? {
        string? authHeader = check req.getHeader("Authorization");

        //use guard close
        if (authHeader == null) {
            check caller->respond("Authorization header is missing.");
            return;
        }

        // Remove any "Bearer " prefix from the token if present

        jwt:Payload|http:Unauthorized payload = authenticateJWT(authHeader);

        if payload is http:Unauthorized {
            check caller->respond("Unauthorized");
            return;
        }

        if payload is jwt:Payload {
            log:printInfo("JWT validation successful.");
            string? email = <string?>payload["email"];
            if email == null {
                check caller->respond("Email not found in JWT payload.");
                return;
            }
            //retunr json
            check caller->respond("JWT is valid. Email: " + email);
        }

    }

    resource function post register(http:Caller caller, http:Request req) returns error? {

        json payload = {};
        var payloadResult = req.getJsonPayload();
        if (payloadResult is json) {
            payload = payloadResult;
        } else {
            checkpanic caller->respond({"error": "Invalid JSON payload"});
        }

        string email = (check payload.email).toString();
        string id = (check payload.id).toString();
        string name = (check payload.name).toString();
        string image = (check payload.image).toString();
        sql:ParameterizedQuery query = `INSERT INTO users (email, id, name, image) 
                        VALUES (${email}, CAST(${id} AS UUID), ${name}, ${image}) 
                        ON CONFLICT (id) DO NOTHING`;

        var result = self.dbClient->execute(query);
        if (result is sql:ExecutionResult) {
            log:printInfo("User registered successfully");

            // Create a JSON object with the registered user details
            json registeredUser = {
                "email": email,
                "id": id,
                "name": name,
                "image": image
            };

            // Send the registered user details back to the caller
            checkpanic caller->respond({
                "message": "User registered successfully",
                "user": registeredUser
            });
        } else if (result is error) {
            log:printError("Error occurred while registering user", result);
            checkpanic caller->respond({"error": "Failed to register user"});
        }
    }

    resource function get buckets() returns json[] {
        var result = amazonS3Client->listBuckets();
        if (result is s3:Bucket[]|error) {
            if (result is s3:Bucket[]) {
                json[] buckets = [];
                foreach var bucket in result {
                    buckets.push({
                        "name": bucket.name,
                        "creationDate": bucket.creationDate.toString()
                    });
                }
                return buckets;
            } else {
                log:printError("Error occurred while listing buckets", result);
                return [];
            }
        }

    }

    resource function post upload(http:Caller caller, http:Request req) returns error? {
        // Get all body parts of the multipart request
        mime:Entity[] bodyParts = check req.getBodyParts();

        // Log the total number of body parts received
        log:printDebug("Total body parts received: " + bodyParts.length().toString());

        // Initialize variables to hold extracted values
        string bucketName = "";
        string key = "";
        byte[] fileContent = [];

        // Loop through each part and log its details
        foreach var part in bodyParts {
            // Log details about the current body part
            log:printDebug("Processing part with content type: " + part.getContentType());

            mime:ContentDisposition? contentDisposition = part.getContentDisposition();
            if contentDisposition is mime:ContentDisposition {
                // Log the content disposition for debugging
                log:printDebug("Content-Disposition Name: " + contentDisposition.name);

                // Check if this part is the 'file' part
                if contentDisposition.disposition == "attachment" || contentDisposition.name == "file" {
                    fileContent = check part.getByteArray();
                    log:printDebug("Extracted file content of size: " + fileContent.length().toString());
                } else if contentDisposition.name == "bucketName" {
                    bucketName = check part.getText();
                    log:printDebug("Extracted bucketName: " + bucketName);
                } else if contentDisposition.name == "key" {
                    key = check part.getText();
                    log:printDebug("Extracted key: " + key);
                }
            } else {
                // Log when no content disposition is found
                log:printWarn("No content disposition found for this part.");
            }
        }

        // Check if all required fields are extracted
        if bucketName == "" || key == "" || fileContent.length() == 0 {
            log:printError("Missing required fields or file. bucketName: '" + bucketName + "', key: '" + key + "', fileContentSize: " + fileContent.length().toString());
            checkpanic caller->respond({"error": "Missing required fields or file"});
            return;
        }

        // Log that all fields are present
        log:printInfo("All fields present. Uploading file to bucket: " + bucketName + " with key: " + key);

        // Call the S3 client to upload the file
        var result = amazonS3Client->createObject(bucketName, key, fileContent);
        if (result is error) {
            log:printError("Error occurred while uploading object", result);
            checkpanic caller->respond({"error": "Failed to upload object"});
        } else {
            log:printInfo("Object uploaded successfully");
            checkpanic caller->respond({"message": "Object uploaded successfully"});
        }
    }
}

@http:ServiceConfig {
    cors: {
        allowOrigins: ["http://localhost:3000"],
        allowMethods: ["GET", "PUT", "POST", "DELETE", "OPTIONS"],
        allowHeaders: ["Authorization", "Content-Type"],
        allowCredentials: true
    }
}
service /events on httpListener {
    final postgresql:Client databaseClient;

    public function init() returns error? {
        self.databaseClient = check new (host, username, password, databaseName, port);
        log:printInfo("Successfully connected to the database.");
    }

    resource function get .() returns string {
        return "Welcome to event";
    }

    resource function get all() returns json[] {
        sql:ParameterizedQuery query = `SELECT id,name, date, time, location,image, description FROM events`;
        stream<record {|string id; string name; string description; string date; string time; string location; string image;|}, error?> resultStream = self.databaseClient->query(query);

        json[] events = [];
        //record {|string id; string name; string description; string date; string time; string location; string image;|}? event;

        record {|string id; string name; string description; string date; string time; string location; string image;|}? event;

        while true {
            var result = resultStream.next();
            if result is error {
                log:printError("Error occurred while fetching events", result);
            } else if result is record {|record {|string id; string name; string description; string date; string time; string location; string image;|} value;|} {
                log:printInfo("Result: " + result.toString());
            }
            if result is error {
                break;
            } else if result is () {
                break;
            } else {
                // Extract the inner record from result
                var innerResult = result.value;
                if innerResult is record {|string id; string name; string description; string date; string time; string location; string image;|} {
                    event = innerResult;
                    if event is record {|string id; string name; string description; string date; string time; string location; string image;|} {
                        events.push({
                            "id": event.id,
                            "name": event.name,
                            "description": event.description,
                            "date": event.date,
                            "time": event.time,
                            "location": event.location,
                            "image": event.image
                        });
                    }
                }
            }
        }
        return events;
    }

    resource function post add(http:Caller caller, http:Request req) returns error? {
        mime:Entity[] bodyParts = check req.getBodyParts();
        string createdBy = "";

        string? authHeader = check req.getHeader("Authorization");

        //use guard close
        if (authHeader == null) {
            check caller->respond("Authorization header is missing.");
            return;
        }

        jwt:Payload|http:Unauthorized payload = authenticateJWT(authHeader);

        if payload is http:Unauthorized {
            check caller->respond("Unauthorized");
            return;
        }

        if payload is jwt:Payload {
            //log:printInfo("JWT validation successful.");
            string? sub = <string?>payload["sub"];
            if sub == null {
                check caller->respond("User not found in JWT payload.");
                return;
            }
            createdBy = sub;

        }

        // Initialize variables to hold extracted values
        string name = "";
        string date = "";
        string time = "";
        string location = "";
        int availableTickets = 0;
        float ticketPrice = 0.0;
        string slug = "";
        string imageExtension = ".png";
        string imageUrl = ""; // S3 image URL
        boolean mealProvides = false;
        string description = "";

        byte[] fileContent = [];

        foreach var part in bodyParts {
            mime:ContentDisposition? contentDisposition = part.getContentDisposition();
            if contentDisposition is mime:ContentDisposition {
                if contentDisposition.disposition == "attachment" || contentDisposition.name == "file" {
                    fileContent = check part.getByteArray();
                } else if contentDisposition.name == "name" {
                    name = check part.getText();
                } else if contentDisposition.name == "date" {
                    date = check part.getText();
                } else if contentDisposition.name == "time" {
                    time = check part.getText();
                } else if contentDisposition.name == "location" {
                    location = check part.getText();
                } else if contentDisposition.name == "available_tickets" {
                    availableTickets = check int:fromString(check part.getText());
                } else if contentDisposition.name == "ticket_price" {
                    ticketPrice = check float:fromString(check part.getText());
                } else if contentDisposition.name == "slug" {
                    slug = check part.getText();
                } else if contentDisposition.name == "meal_provides" {
                    mealProvides = check boolean:fromString(check part.getText());
                } else if contentDisposition.name == "description" {
                    description = check part.getText();
                } else if contentDisposition.name == "image_extension" {
                    imageExtension = check part.getText();
                }
            }
        }

        // Ensure that all required fields are available
        if name == "" || fileContent.length() == 0 || date == "" || time == "" || location == "" || slug == "" || createdBy == "" {
            checkpanic caller->respond({"error": "Missing required fields"});
            return;
        }

        string key = "images/" + slug + imageExtension;
        var uploadResult = amazonS3Client->createObject(AWS_BUCKET, key, fileContent);

        if (uploadResult is error) {
            log:printError("Error occurred while uploading file to S3", uploadResult);
            checkpanic caller->respond({"error": "Failed to upload file to S3"});
            return;
        }

        // Get the S3 URL
        imageUrl = "https://" + AWS_BUCKET + ".s3." + AWS_REGION + ".amazonaws.com/" + key;

        // Insert event data into the database
        sql:ParameterizedQuery query = `INSERT INTO public.events 
        (name, date, time, location, available_tickets, ticket_price, slug, image, meal_provides, description, created_by) 
        VALUES (${name}, ${date}::date, ${time}::time, ${location}, ${availableTickets}, ${ticketPrice}, ${slug}, ${imageUrl}, ${mealProvides}, ${description}, CAST(${createdBy} AS UUID))`;

        var result = self.databaseClient->execute(query);

        if (result is sql:ExecutionResult) {
            log:printInfo("Event added successfully");

            // Create a JSON object with the added event details
            json addedEvent = {
                "name": name,
                "date": date,
                "time": time,
                "location": location,
                "available_tickets": availableTickets,
                "ticket_price": ticketPrice,
                "slug": slug,
                "image": imageUrl,
                "meal_provides": mealProvides,
                "description": description,
                "created_by": createdBy
            };

            // Send the added event details back to the caller
            checkpanic caller->respond({
                "message": "Event added successfully",
                "event": addedEvent
            });
        } else if (result is error) {
            log:printError("Error occurred while adding event", result);
            checkpanic caller->respond({"error": "Failed to add event"});
        }
    }

    resource function get checkSlug(http:Caller caller, http:Request req) returns error? {
        // Extract the slug from the query parameters
        string? slug = req.getQueryParamValue("slug");

        // If no slug is provided, return an error
        if slug is () {
            checkpanic caller->respond({"error": "Slug parameter is missing"});
            return;
        }

        // Query the database to check if the slug exists
        sql:ParameterizedQuery query = `SELECT COUNT(1) AS count FROM public.events WHERE slug = ${slug}`;

        // Execute the query and get the result as a single integer
        int? count = check self.databaseClient->queryRow(query);

        // Check if the query was successful
        if count is int {
            // If count is greater than 0, the slug is taken
            if count > 0 {
                checkpanic caller->respond({"available": false, "message": "Slug is already taken"});
            } else {
                checkpanic caller->respond({"available": true, "message": "Slug is available"});
            }
        } else {
            // Handle the case when the query failed
            checkpanic caller->respond({"error": "Failed to check slug availability"});
        }
    }

    resource function get userowned(http:Caller caller, http:Request req) returns error? {

        string createdBy = "";

        string? authHeader = check req.getHeader("Authorization");

        //use guard close
        if (authHeader == null) {
            checkpanic caller->respond({"error": "Authorization header is missing."});
            return;
        }

        jwt:Payload|http:Unauthorized payload = authenticateJWT(authHeader);

        if payload is http:Unauthorized {
            checkpanic caller->respond({"error": "Unauthorized"});
            return;
        }

        if payload is jwt:Payload {
            log:printInfo("JWT validation successful.");
            string? sub = <string?>payload["sub"];
            if sub == null {
                check caller->respond("User not found in JWT payload.");
                return;
            }
            createdBy = sub;

        }

        // Query to fetch the list of events
        sql:ParameterizedQuery query = `SELECT 
            id, 
            name, 
            date, 
            time, 
            location, 
            tickets_sold, 
            "default", 
            available_tickets, 
            ticket_price, 
            slug, 
            meal_provides, 
            description, 
            status 
        FROM public.events_view
        WHERE created_by = CAST(${createdBy} AS UUID)`;

        // Execute the query and specify the row type
        stream<Event, sql:Error?> resultStream = self.databaseClient->query(query, Event);

        // Initialize a JSON array to hold the event details
        json[] eventsList = [];

        // Iterate through the stream and add each event to the list
        while true {
            var result = resultStream.next();
            if result is record {|Event value;|} {
                Event event = result.value;
                json eventDetails = {
                    "id": event.id.toString(),
                    "name": event.name,
                    "date": event.date,
                    "time": event.time,
                    "location": event.location,
                    "tickets_sold": event.tickets_sold,
                    "default": event.default,
                    "available_tickets": event.available_tickets,
                    "ticket_price": event.ticket_price,
                    "slug": event.slug,
                    "meal_provides": event.meal_provides,
                    "description": event.description,
                    "status": event.status
                };
                eventsList.push(eventDetails);
            } else if result is error {
                log:printError("Error occurred while fetching events", result);
                checkpanic caller->respond({"error": "Failed to fetch events"});
                return;
            } else {
                break;
            }
        }

        // Respond with the list of events
        checkpanic caller->respond(eventsList);

    }

    resource function get details(http:Caller caller, http:Request req) returns error? {

        string createdBy = "";

        string? authHeader = check req.getHeader("Authorization");

        //use guard close
        if (authHeader == null) {
            checkpanic caller->respond({"error": "Authorization header is missing."});
            return;
        }

        jwt:Payload|http:Unauthorized payload = authenticateJWT(authHeader);

        if payload is http:Unauthorized {
            checkpanic caller->respond({"error": "Unauthorized"});
            return;
        }

        if payload is jwt:Payload {
            //log:printInfo("JWT validation successful.");
            string? sub = <string?>payload["sub"];
            if sub == null {
                check caller->respond("User not found in JWT payload.");
                return;
            }
            createdBy = sub;

        }

        // Extract the slug from the query parameters
        string? slug = req.getQueryParamValue("slug");

        // If no slug is provided, return an error
        if slug is () {
            checkpanic caller->respond({"error": "Slug parameter is missing"});
            return;
        }

        // Query to fetch the list of events
        sql:ParameterizedQuery query = `SELECT 
            id,
            image,
            name, 
            date, 
            time, 
            location, 
            tickets_sold, 
            'default', 
            available_tickets, 
            ticket_price, 
            slug, 
            meal_provides, 
            description, 
            status 
        FROM public.events_view
        WHERE created_by = CAST(${createdBy} AS UUID)
        AND slug = ${slug}`;

        // Execute the query and specify the row type
        stream<Event, sql:Error?> resultStream = self.databaseClient->query(query, Event);

        // Initialize a JSON array to hold the event details
        json[] eventsList = [];

        // Iterate through the stream and add each event to the list
        while true {
            var result = resultStream.next();
            if result is record {|Event value;|} {
                Event event = result.value;
                json eventDetails = {
                    "id": event.id.toString(),
                    "name": event.name,
                    "image": event.image,
                    "date": event.date,
                    "time": event.time,
                    "location": event.location,
                    "tickets_sold": event.tickets_sold,
                    "default": event.default,
                    "available_tickets": event.available_tickets,
                    "ticket_price": event.ticket_price,
                    "slug": event.slug,
                    "meal_provides": event.meal_provides,
                    "description": event.description,
                    "status": event.status
                };
                eventsList.push(eventDetails);
            } else if result is error {
                log:printError("Error occurred while fetching events", result);
                checkpanic caller->respond({"error": "Failed to fetch events"});
                return;
            } else {
                break;
            }
        }

        // Respond with the list of events
        checkpanic caller->respond(eventsList);

    }

    resource function post markDefault(http:Caller caller, http:Request req) returns error? {
        // Parse the request body
        json payload = check req.getJsonPayload();

        string userId = "";
        string? authHeader = check req.getHeader("Authorization");

        //use guard close
        if (authHeader == null) {
            checkpanic caller->respond({"error": "Authorization header is missing."});
            return;
        }

        jwt:Payload|http:Unauthorized jwtpayload = authenticateJWT(authHeader);

        if jwtpayload is http:Unauthorized {
            checkpanic caller->respond({"error": "Unauthorized"});
            return;
        }

        if jwtpayload is jwt:Payload {
            //log:printInfo("JWT validation successful.");
            string? sub = <string?>jwtpayload["sub"];
            if sub != null {
                userId = sub;
            } else {
                check caller->respond("User not found in JWT payload.");
                return;
            }

        }

        // Extract the event_id and user_id from the request payload
        string? eventId = payload.event_id is () ? () : (check payload.event_id).toString();

        // Check if both event_id and user_id are provided
        if eventId is () {
            checkpanic caller->respond({"error": "event_id must be provided"});
            return;
        }

        // Define the query to call the PostgreSQL function
        sql:ParameterizedQuery query = `SELECT public.mark_event_as_default(CAST(${eventId} AS UUID), CAST(${userId} AS UUID))`;

        // Execute the query
        var result = self.databaseClient->execute(query);

        // Check if the query execution was successful
        if result is sql:ExecutionResult {
            log:printInfo("Event marked as default successfully");
            checkpanic caller->respond({"message": "Event marked as default successfully"});
        } else if result is error {
            log:printError("Error occurred while marking event as default", result);
            checkpanic caller->respond({"error": "Failed to mark event as default"});
        }
    }

    resource function post uploadImage(http:Caller caller, http:Request req) returns error? {
        // Get all body parts of the multipart request
        mime:Entity[] bodyParts = check req.getBodyParts();

        // Log the total number of body parts received
        log:printDebug("Total body parts received: " + bodyParts.length().toString());

        string key = "";
        byte[] fileContent = [];

        // Loop through each part and log its details
        foreach var part in bodyParts {
            // Log details about the current body part
            log:printDebug("Processing part with content type: " + part.getContentType());

            mime:ContentDisposition? contentDisposition = part.getContentDisposition();
            if contentDisposition is mime:ContentDisposition {
                // Log the content disposition for debugging
                log:printDebug("Content-Disposition Name: " + contentDisposition.name);

                // Check if this part is the 'file' part
                if contentDisposition.disposition == "attachment" || contentDisposition.name == "file" {
                    fileContent = check part.getByteArray();
                    log:printDebug("Extracted file content of size: " + fileContent.length().toString());
                } else if contentDisposition.name == "slug" {
                    key = check part.getText();

                }
            } else {
                // Log when no content disposition is found
                log:printWarn("No content disposition found for this part.");
            }
        }

        // Check if all required fields are extracted
        if key == "" || fileContent.length() == 0 {
            log:printError("Missing required fields or file. key: '" + key + "', fileContentSize: " + fileContent.length().toString());
            checkpanic caller->respond({"error": "Missing required fields or file"});
            return;
        }

        // Log that all fields are present
        log:printInfo("All fields present. Uploading file to bucket: " + AWS_BUCKET + " with key: " + key);

        string uploadPath = "images/" + key;
        // Call the S3 client to upload the file
        var result = amazonS3Client->createObject(AWS_BUCKET, uploadPath, fileContent);
        if (result is error) {
            log:printError("Error occurred while uploading object", result);
            checkpanic caller->respond({"error": "Failed to upload object"});
        } else {
            log:printInfo("Object uploaded successfully");
            checkpanic caller->respond({
                "message": "Object uploaded successfully",
                "url": "https://" + AWS_BUCKET + ".s3." + AWS_REGION + ".amazonaws.com/" + uploadPath
            });
        }
    }

    resource function post update(http:Caller caller, http:Request req) returns error? {
        // Parse the request body
        json payload = check req.getJsonPayload();

        string userId = "";

        string? authHeader = check req.getHeader("Authorization");

        //use guard close
        if (authHeader == null) {
            checkpanic caller->respond({"error": "Authorization header is missing."});
            return;
        }

        jwt:Payload|http:Unauthorized jwtpayload = authenticateJWT(authHeader);

        if jwtpayload is http:Unauthorized {
            checkpanic caller->respond({"error": "Unauthorized"});
            return;
        }

        if jwtpayload is jwt:Payload {
            //log:printInfo("JWT validation successful.");
            string? sub = <string?>jwtpayload["sub"];
            if sub != null {
                userId = sub;
            } else {
                check caller->respond("User not found in JWT payload.");
                return;
            }

        }

        // Extract the event_id and user_id from the request payload
        string? eventId = payload.event_id is () ? () : (check payload.event_id).toString();
        string? name = payload.name is () ? () : (check payload.name).toString();
        string? date = payload.date is () ? () : (check payload.date).toString();
        string? time = payload.time is () ? () : (check payload.time).toString();
        string? location = payload.location is () ? () : (check payload.location).toString();
        string? description = payload.description is () ? () : (check payload.description).toString();

        int availableTickets = 0;
        float ticket_price = 0.0;

        availableTickets = check payload.available_tickets;
        ticket_price = check payload.ticket_price;

        string? slug = payload.slug is () ? () : (check payload.slug).toString();
        string? imageUrl = payload.image is () ? () : (check payload.image).toString();
        boolean mealProvides = false;

        mealProvides = check payload.meal_provides;

        // Check if both event_id and user_id are provided
        if eventId is () {
            checkpanic caller->respond({"error": "event_id must be provided"});
            return;
        }

        // Insert event data into the database
        sql:ParameterizedQuery query = `UPDATE public.events 
        SET name = ${name}, date = ${date}::date, time = ${time}::time, location = ${location}, 
        available_tickets = ${availableTickets}, ticket_price = ${ticket_price}, slug = ${slug}, 
        image = ${imageUrl}, meal_provides = ${mealProvides}, description = ${description} 
        WHERE id = CAST(${eventId} AS UUID) AND created_by = CAST(${userId} AS UUID)`;

        var result = self.databaseClient->execute(query);

        if (result is sql:ExecutionResult) {
            log:printInfo("Event update successfully");

            // Create a JSON object with the added event details
            json addedEvent = {
                "name": name,
                "date": date,
                "time": time,
                "location": location,
                "available_tickets": availableTickets,
                "ticket_price": ticket_price,
                "slug": slug,
                "image": imageUrl,
                "meal_provides": mealProvides,
                "description": description,
                "created_by": userId
            };

            // Send the added event details back to the caller
            checkpanic caller->respond({
                "message": "Event updated successfully",
                "event": addedEvent
            });
        } else if (result is error) {
            log:printError("Error occurred while adding event", result);
            checkpanic caller->respond({"error": "Failed to add event"});
        }
    }

    resource function post purchase(http:Caller caller, http:Request req) returns error? {
        // Parse the JSON payload
        json payload = check req.getJsonPayload();

        // string? eventId = payload.event_id is () ? () : (check payload.event_id).toString();

        // Extract relevant fields from the payload
        string? ticketId = payload.ticket_id is () ? () : (check payload.ticket_id).toString();
        string? name = payload.name is () ? () : (check payload.name).toString();
        string? email = payload.email is () ? () : (check payload.email).toString();
        string? mobile = payload.mobile is () ? () : (check payload.mobile).toString();
        int? mealType = payload.meal_type is () ? () : (check int:fromString((check payload.meal_type).toString()));
        int? paymentMethod = payload.payment_method is () ? () : (check int:fromString((check payload.payment_method).toString()));
        string? eventName = payload.event_name is () ? () : (check payload.event_name).toString();
        string? eventImage = payload.event_image is () ? () : (check payload.event_image).toString();
        int? status = payload.status is () ? () : (check int:fromString((check payload.status).toString()));
        string? eventId = payload.event_id is () ? () : (check payload.event_id).toString();

        // Validate required fields
        if ticketId is () || name is () || email is () || mobile is () ||
            mealType is () || paymentMethod is () || eventName is () || eventImage is () || eventId is () {
            checkpanic caller->respond({"error": "Missing required fields"});
            return;
        }

        // Define the query to call the PostgreSQL function
        sql:ParameterizedQuery query;

        if status is () {
            // If status is null, call the function without status
            query = `SELECT public.process_ticket_purchase(
            CAST(${ticketId} AS UUID),
            ${name},
            ${email},
            ${mobile},
            CAST(${mealType} AS SMALLINT),
            CAST(${paymentMethod} AS SMALLINT),
            ${eventName},
            ${eventImage},
            NULL,
            CAST(${eventId} AS UUID)
        )`;
        } else {
            // If status is provided, call the function with status
            query = `SELECT public.process_ticket_purchase(
            CAST(${ticketId} AS UUID),
            ${name},
            ${email},
            ${mobile},
            CAST(${mealType} AS SMALLINT),
            CAST(${paymentMethod} AS SMALLINT),
            ${eventName},
            ${eventImage},
            CAST(${status} AS SMALLINT),
            CAST(${eventId} AS UUID)
        )`;
        }

        // Execute the query
        var result = self.databaseClient->execute(query);

        // Check the result of the query execution
        if result is sql:ExecutionResult {
            log:printInfo("Ticket purchase processed successfully");
            checkpanic caller->respond({"message": "Ticket purchase processed successfully"});
        } else if result is error {
            log:printError("Error occurred while processing ticket purchase", result);
            checkpanic caller->respond({"error": "Failed to process ticket purchase"});
        }
    }

}

@http:ServiceConfig {
    cors: {
        allowOrigins: ["http://localhost:3000"],
        allowMethods: ["GET", "PUT", "POST", "DELETE", "OPTIONS"],
        allowHeaders: ["Authorization", "Content-Type"],
        allowCredentials: true
    }
}
service /bank_account on httpListener {
    final postgresql:Client databaseClient;

    public function init() returns error? {
        self.databaseClient = check new (host, username, password, databaseName, port);
        log:printInfo("Successfully connected to the database.");
    }

    resource function get .() returns string {
        return "Welcome to bank account";
    }

    resource function get all() returns json[] {
        sql:ParameterizedQuery query = `SELECT user_id, account_name, bank, account_number, branch, to_be_paid FROM bank_accounts`;
        stream<record {|string user_id; string account_name; string bank; string account_number; string branch; float to_be_paid;|}, error?> resultStream = self.databaseClient->query(query);

        json[] bankAccounts = [];
        record {|string user_id; string account_name; string bank; string account_number; string branch; float to_be_paid;|}? bankAccount;

        while true {
            var result = resultStream.next();
            if result is error {
                log:printError("Error occurred while fetching bank accounts", result);
            } else if result is record {|record {|string user_id; string account_name; string bank; string account_number; string branch; float to_be_paid;|} value;|} {
                log:printInfo("Result: " + result.toString());
            }
            if result is error {
                continue;
            } else if result is () {
                break;
            } else {
                // Extract the inner record from result
                var innerResult = result.value;
                if innerResult is record {|string user_id; string account_name; string bank; string account_number; string branch; float to_be_paid;|} {
                    bankAccount = innerResult;
                    if bankAccount is record {|string user_id; string account_name; string bank; string account_number; string branch; float to_be_paid;|} {
                        bankAccounts.push({
                            "id": bankAccount.user_id,
                            "account_number": bankAccount.account_number,
                            "bank_name": bankAccount.bank,
                            "branch": bankAccount.branch,
                            "account_holder_name": bankAccount.account_name,
                            "user_id": bankAccount.user_id
                        });
                    }
                }
            }
        }
        return bankAccounts;
    }

    resource function post add(http:Caller caller, http:Request req) returns error? {
        json payload;
        var payloadResult = req.getJsonPayload();
        if (payloadResult is json) {
            payload = payloadResult;
        } else {
            checkpanic caller->respond({"error": "Invalid JSON payload"});
            return;
        }

        string user_id = (check payload.user_id).toString();
        string account_name = (check payload.account_name).toString();
        string bank = (check payload.bank).toString();
        string account_number = (check payload.account_number).toString();
        string branch = (check payload.branch).toString();
        float to_be_paid = 0.00;

        // Handle 'to_be_paid' field
        if payload.to_be_paid is float {
            to_be_paid = check payload.to_be_paid;
        } else if payload.to_be_paid is int {
            var parsedFloat = float:fromString((check payload.to_be_paid).toString());
            if parsedFloat is float {
                to_be_paid = parsedFloat;
            } else {
                checkpanic caller->respond({"error": "Invalid 'to_be_paid' value: must be a number"});
                return;
            }
        } else if payload.to_be_paid is string {
            var parsedFloat = float:fromString((check payload.to_be_paid).toString());
            if parsedFloat is float {
                to_be_paid = parsedFloat;
            } else {
                checkpanic caller->respond({"error": "Invalid 'to_be_paid' value: must be a number"});
                return;
            }
        } else {
            checkpanic caller->respond({"error": "Invalid 'to_be_paid' value: unsupported type"});
            return;
        }

        // Ensure all required fields are provided
        if user_id == "" || account_name == "" || bank == "" || account_number == "" || branch == "" {
            checkpanic caller->respond({"error": "Missing required fields"});
            return;
        }

        // Insert the new bank account into the database
        sql:ParameterizedQuery query = `INSERT INTO bank_accounts (user_id, account_name, bank, account_number, branch, to_be_paid)
                                        VALUES (CAST(${user_id} AS UUID), ${account_name}, ${bank}, ${account_number}, ${branch}, ${to_be_paid})`;

        var result = self.databaseClient->execute(query);

        if result is sql:ExecutionResult {
            log:printInfo("Bank account added successfully");

            // Create a JSON object with the added bank account details
            json addedBankAccount = {
                "user_id": user_id,
                "account_name": account_name,
                "bank": bank,
                "account_number": account_number,
                "branch": branch,
                "to_be_paid": to_be_paid
            };

            // Send the added bank account details back to the caller
            checkpanic caller->respond({
                "message": "Bank account added successfully",
                "bank_account": addedBankAccount
            });
        } else if result is error {
            log:printError("Error occurred while adding bank account", result);
            checkpanic caller->respond({"error": "Failed to add bank account"});
        }
    }

    resource function get getBankAccountsByUserId(http:Caller caller, http:Request req) returns error? {
        // Extract user_id from the query parameters
        string? user_idQueryParam = req.getQueryParamValue("user_id");

        // Ensure user_id is provided
        if user_idQueryParam is string {
            string user_id = user_idQueryParam;
            if user_id == "" {
                checkpanic caller->respond({"error": "Missing 'user_id' query parameter"});
                return;
            }

            // Query the bank accounts based on user_id
            sql:ParameterizedQuery query = `SELECT user_id, account_name, bank, account_number, branch, to_be_paid 
                                            FROM bank_accounts 
                                            WHERE user_id = CAST(${user_id} AS UUID)`;

            // Execute the query and get the results
            stream<record {|string user_id; string account_name; string bank; string account_number; string branch; float to_be_paid;|}, error?> resultStream = self.databaseClient->query(query);

            json[] bankAccounts = [];
            record {|string user_id; string account_name; string bank; string account_number; string branch; float to_be_paid;|}? bankAccount;

            // Iterate through the result stream
            while true {
                var result = resultStream.next();
                if result is error {
                    log:printError("Error occurred while fetching bank accounts", result);
                    // Instead of using checkpanic, just respond with an error and return
                    _ = check caller->respond({"error": "Failed to fetch bank accounts"});
                    return; // Exit the function
                } else if result is () {
                    // End of stream
                    break;
                } else {
                    bankAccount = result.value;
                    if bankAccount is record {|string user_id; string account_name; string bank; string account_number; string branch; float to_be_paid;|} {
                        // Push the result into the bankAccounts array
                        bankAccounts.push({
                            "user_id": bankAccount.user_id,
                            "account_name": bankAccount.account_name,
                            "bank": bankAccount.bank,
                            "account_number": bankAccount.account_number,
                            "branch": bankAccount.branch,
                            "to_be_paid": bankAccount.to_be_paid
                        });
                    }
                }
            }

            // Return the bank accounts related to the user_id
            if bankAccounts.length() > 0 {
                checkpanic caller->respond({
                    "message": "Bank accounts fetched successfully",
                    "bank_accounts": bankAccounts
                });
            } else {
                checkpanic caller->respond({
                    "message": "No bank accounts found for the given user_id"
                });
            }
        } else {
            checkpanic caller->respond({"error": "Missing 'user_id' query parameter"});
        }
    }

    resource function delete deleteBankAccount(http:Caller caller, http:Request req) returns error? {
        json payload;
        var payloadResult = req.getJsonPayload();
        if (payloadResult is json) {
            payload = payloadResult;
        } else {
            checkpanic caller->respond({"error": "Invalid JSON payload"});
            return;
        }

        // Extract user_id and account_number from the payload
        string user_id = (check payload.user_id).toString();
        string account_number = (check payload.account_number).toString();

        // Ensure user_id and account_number are provided
        if user_id == "" || account_number == "" {
            checkpanic caller->respond({"error": "Missing 'user_id' or 'account_number' field"});
            return;
        }

        // Delete the bank account from the database
        sql:ParameterizedQuery query = `DELETE FROM bank_accounts 
                                     WHERE user_id = CAST(${user_id} AS UUID) 
                                     AND account_number = ${account_number}`;

        var result = self.databaseClient->execute(query);

        if result is sql:ExecutionResult {
            log:printInfo("Bank account deleted successfully");

            checkpanic caller->respond({
                "message": "Bank account deleted successfully"
            });
        } else if result is error {
            log:printError("Error occurred while deleting bank account", result);
            checkpanic caller->respond({"error": "Failed to delete bank account"});
        }
    }

}
