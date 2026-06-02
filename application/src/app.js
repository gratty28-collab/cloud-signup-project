const express = require('express');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, PutCommand } = require('@aws-sdk/lib-dynamodb');

const app = express();
app.use(express.json()); // Allows us to parse JSON bodies

// Initialize the AWS DynamoDB Client
// When running in EKS, the AWS SDK automatically picks up the IAM Role from the pod environment
const client = new DynamoDBClient({ region: process.env.AWS_REGION || 'us-east-1' });
const docClient = DynamoDBDocumentClient.from(client);

const TABLE_NAME = process.env.DATABASE_TABLE || 'users-table';
const PORT = process.env.PORT || 3000;

// Health check endpoint (Crucial for Kubernetes readiness/liveness probes!)
app.get('/health', (req, res) => {
    res.status(200).json({ status: 'UP', timestamp: new Date() });
});

// Signup Endpoint
app.post('/signup', async (req, res) => {
    const { name, email } = req.body;

    if (!name || !email) {
        return res.status(400).json({ error: 'Name and email are required' });
    }

    const newUser = {
        userId: email, // Using email as our unique Partition Key
        name: name,
        signupDate: new Date().toISOString()
    };

    try {
        await docClient.send(new PutCommand({
            TableName: TABLE_NAME,
            Item: newUser
        }));
        
        console.log(`Successfully signed up user: ${email}`);
        return res.status(201).json({ message: 'User registered successfully!', user: newUser });
    } catch (error) {
        console.error('Database error:', error);
        return res.status(500).json({ error: 'Internal server error saving user data' });
    }
});

app.listen(PORT, () => {
    console.log(`Signup application running on port ${PORT}`);
});