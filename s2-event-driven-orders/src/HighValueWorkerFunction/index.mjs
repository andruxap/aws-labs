export const handler = async (event) => {
  console.log("Received high-value order event:", JSON.stringify(event, null, 2));

  for (const record of event.Records) {
    const body = JSON.parse(record.body);

    console.log("HIGH-VALUE ORDER");
    console.log(`Order ID: ${body.orderId}`);
    console.log(`Amount: ${body.amount}`);
    console.log(`Product: ${body.product}`);
    console.log(`Priority: ${body.priority}`);
    console.log(`Routed At: ${body.routedAt}`);

    // In a real system this is where you would:
    // - run deeper fraud checks
    // - trigger a manual review workflow
    // - notify a risk/finance team
    // - apply special SLAs or routing
  }

  return {};
};
