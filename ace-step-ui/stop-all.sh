#!/bin/bash
# ACE-Step UI Stop All Services Script

echo "Stopping all ACE-Step services..."

echo "Stopping Wan2.2 processes..."
pkill -f "Wan2.2" || true

echo "Stopping ACE-Step-1.5 API server..."
if [ -f ../ACE-Step-1.5/logs/api.pid ]; then
    API_PID=$(cat ../ACE-Step-1.5/logs/api.pid)
    if kill -0 $API_PID 2>/dev/null; then
        echo "Stopping API server (PID: $API_PID)..."
        kill $API_PID
    fi
    rm ../ACE-Step-1.5/logs/api.pid
fi


if [ -f logs/backend.pid ]; then
    BACKEND_PID=$(cat logs/backend.pid)
    if kill -0 $BACKEND_PID 2>/dev/null; then
        echo "Stopping backend (PID: $BACKEND_PID)..."
        kill $BACKEND_PID
    fi
    rm logs/backend.pid
fi

if [ -f logs/frontend.pid ]; then
    FRONTEND_PID=$(cat logs/frontend.pid)
    if kill -0 $FRONTEND_PID 2>/dev/null; then
        echo "Stopping frontend (PID: $FRONTEND_PID)..."
        kill $FRONTEND_PID
    fi
    rm logs/frontend.pid
fi

echo "All services stopped!"
