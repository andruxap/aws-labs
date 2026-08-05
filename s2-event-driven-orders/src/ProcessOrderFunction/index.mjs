import { DynamoDBClient, UpdateItemCommand } from "@aws-sdk/client-dynamodb";
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";

const ddbClient = new DynamoDBClient();
const sqsClient = new SQSClient();
const snsClient = new SNSClient();

export const handler = async (event) => {
  console.log("Received DynamoDB Stream event:", JSON.stringify(event, null, 2));

  const tableName = process.env.ORDERS_TABLE_NAME;
  const queueUrl = process.env.ORDER_QUEUE_URL;
  const records = event.Records || [];

  for (const record of records) {
    const eventName = record.eventName;

    // Guard against the writeback loop: this function updates the same table it
    // reads from, which emits a MODIFY event that would re-trigger it forever.
    if (eventName !== "INSERT") {
      console.log(`Skipping event ${eventName}`);
      continue;
    }

    const newImage = record.dynamodb.NewImage;
    if (!newImage) {
      console.log("No NewImage found, skipping");
      continue;
    }

    const orderId = newImage.orderId.S;
    const customerName = newImage.customerName.S;
    const amount = Number(newImage.amount.N);
    const product = newImage.product.S;
    const notes = newImage.notes?.S || "";
    const createdAt = newImage.createdAt.S;

    console.log(
      `ProcessOrderFunction picked up order ${orderId} (${product}) amount: ${amount}`
    );

    // 1) Mark the order as PROCESSING
    const processingStartedAt = new Date().toISOString();

    const updateParams = new UpdateItemCommand({
      TableName: tableName,
      Key: { orderId: { S: orderId } },
      UpdateExpression: "SET #s = :status, processingStartedAt = :processingStartedAt",
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: {
        ":status": { S: "PROCESSING" },
        ":processingStartedAt": { S: processingStartedAt },
      },
    });

    try {
      await ddbClient.send(updateParams);
      console.log(`Order ${orderId} marked as PROCESSING at ${processingStartedAt}`);
    } catch (error) {
      console.error(`Failed to update order ${orderId} to PROCESSING:`, error);
    }

    // 2) Hand off for downstream processing.
    // amount goes as a JSON number, not a string — the Pipe's numeric filter
    // depends on it.
    const payload = {
      orderId,
      customerName,
      amount,
      product,
      notes,
      createdAt,
      processingStartedAt,
    };

    // Two topologies, selected by config:
    //   ORDER_TOPIC_ARN set -> SNS fan-out. The worker queue and the Pipe's own
    //     source queue each subscribe, so each gets its own copy. This is the fix
    //     for the race described in the README.
    //   otherwise -> publish straight to the worker queue. This is the course's
    //     topology, in which the Pipe and the worker compete for one queue and
    //     the Pipe silently discards everything its filter rejects.
    const topicArn = process.env.ORDER_TOPIC_ARN;

    try {
      if (topicArn) {
        await snsClient.send(
          new PublishCommand({
            TopicArn: topicArn,
            Message: JSON.stringify(payload),
          })
        );
        console.log(`Order ${orderId} published to SNS for fan-out`);
      } else {
        await sqsClient.send(
          new SendMessageCommand({
            QueueUrl: queueUrl,
            MessageBody: JSON.stringify(payload),
          })
        );
        console.log(`Order ${orderId} sent to SQS queue for worker processing`);
      }
    } catch (error) {
      console.error(`Failed to hand off order ${orderId}:`, error);
    }
  }

  return {
    statusCode: 200,
    body: JSON.stringify({ message: "Stream processed and sent to SQS" }),
  };
};
