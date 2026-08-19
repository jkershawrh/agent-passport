FROM golang:1.25.9-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/agent-passport ./cmd/agent-passport

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/agent-passport /usr/local/bin/agent-passport
EXPOSE 9094 8080 8085
ENTRYPOINT ["/usr/local/bin/agent-passport"]
