FROM golang:1.22-alpine AS build
WORKDIR /src
ENV GOFLAGS=-mod=mod CGO_ENABLED=0
COPY go.mod ./
COPY *.go ./
# go.sum is generated here so the build context needs only go.mod + sources.
RUN go mod tidy && go build -trimpath -ldflags="-s -w" -o /out/exporter .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/exporter /exporter
EXPOSE 9145
USER nonroot:nonroot
ENTRYPOINT ["/exporter"]
