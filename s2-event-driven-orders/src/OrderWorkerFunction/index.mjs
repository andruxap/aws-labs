import { DynamoDBClient, UpdateItemCommand } from "@aws-sdk/client-dynamodb";

const ddbClient = new DynamoDBClient();
const tableName = process.env.ORDERS_TABLE_NAME;

export const handler = async (event) => {
  console.log("Received SQS event:", JSON.stringify(event, null, 2));

  for (const record of event.Records) {
    const body = record.body;
    let order;

    try {
      order = JSON.parse(body);
    } catch (error) {
      console.error("Failed to parse message body as JSON:", body);
      throw error; // technical failure — retry, then DLQ
    }

    const { orderId, customerName, amount, product, notes } = order;

    console.log(
      `Worker processing order ${orderId} for ${customerName}, amount: ${amount}, product: ${product}`
    );

    // --- Simulated TECHNICAL failure: notes containing "FAIL" ---
    // Throwing lets SQS retry 3x, then move the message to the DLQ.
    if (typeof notes === "string" && notes.toUpperCase().includes("FAIL")) {
      console.error(
        `Simulated technical failure for order ${orderId} (notes contained 'FAIL')`
      );
      throw new Error(`Simulated worker failure for order ${orderId}`);
    }

    const now = new Date().toISOString();

    // --- Simulated BUSINESS rule: amount > 10000 -> FAILED, no retry ---
    // Retrying would not change the answer, so we consume the message.
    if (amount > 10000) {
      const failCommand = new UpdateItemCommand({
        TableName: tableName,
        Key: { orderId: { S: orderId } },
        UpdateExpression:
          "SET #s = :status, failureReason = :reason, failedAt = :failedAt",
        ExpressionAttributeNames: { "#s": "status" },
        ExpressionAttributeValues: {
          ":status": { S: "FAILED" },
          ":reason": { S: "AMOUNT_ABOVE_LIMIT" },
          ":failedAt": { S: now },
        },
      });

      try {
        await ddbClient.send(failCommand);
        console.log(`Order ${orderId} marked as FAILED (amount above limit)`);
      } catch (error) {
        console.error(`Failed to update order ${orderId} to FAILED:`, error);
      }

      continue; // business rejection — do not retry
    }

    // --- SUCCESS path ---
    const completeCommand = new UpdateItemCommand({
      TableName: tableName,
      Key: { orderId: { S: orderId } },
      UpdateExpression: "SET #s = :status, completedAt = :completedAt",
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: {
        ":status": { S: "COMPLETED" },
        ":completedAt": { S: now },
      },
    });

    try {
      await ddbClient.send(completeCommand);
      console.log(`Order ${orderId} marked as COMPLETED by worker.`);
    } catch (error) {
      console.error(`Failed to update order ${orderId} to COMPLETED:`, error);
      throw error; // technical failure — retry, then DLQ
    }
  }

  return {};
};
