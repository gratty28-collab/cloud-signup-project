# Step 1: Use an official lightweight Node.js base image
FROM node:20-alpine

# Step 2: Set the working directory inside the container
WORKDIR /usr/src/app

# Step 3: Copy package files first to take advantage of Docker caching layers
COPY package*.json ./

# Step 4: Install only production dependencies
RUN npm install --only=production

# Step 5: Copy the application source code
COPY src/ ./src/

# Step 6: Expose the port the app runs on
EXPOSE 3000

# Step 7: Define the command to run the application
CMD [ "npm", "start" ]