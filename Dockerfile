FROM node:24-alpine

ENV instDir /Hatjitsu
WORKDIR ${instDir}
COPY . .
RUN npm ci --omit=dev

USER node
EXPOSE 5000

CMD node server
