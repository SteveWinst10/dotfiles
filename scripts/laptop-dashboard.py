import os
import pandas as pd
import plotly.express as px
import streamlit as st

st.set_page_config(page_title="ROG Telemetry", layout="wide")
st.title("💻 Laptop Power & Thermal Telemetry")

LOG_FILE = os.path.expanduser("~/.local/share/telemetry/laptop_telemetry.csv")

if not os.path.exists(LOG_FILE):
    st.warning("No telemetry log found yet.")
    st.stop()

df = pd.read_csv(LOG_FILE)
if df.empty:
    st.info("Log file is empty.")
    st.stop()

latest = df.iloc[-1]

col1, col2, col3, col4, col5 = st.columns(5)
col1.metric("Battery", f"{latest['Battery_Pct']}%", delta=latest['Power_Source'])
col2.metric("Power Draw", f"{latest['Power_Draw_W']} W", delta=latest['Power_Status'], delta_color="inverse" if latest['Power_Status'] == "ABOVE NORMAL" else "normal")
col3.metric("CPU Temp / Load", f"{latest['CPU_Temp_C']}°C", f"{latest['CPU_Usage_Pct']}% CPU")
col4.metric("GPU Temp / Load", f"{latest['GPU_Temp_C']}°C", f"{latest['GPU_Usage_Pct']}% GPU")
col5.metric("RAM Used", f"{latest['RAM_Used_MB']} MB")

st.divider()

g1, g2 = st.columns(2)
with g1:
    st.plotly_chart(px.line(df, x="Timestamp", y=["Power_Draw_W", "Battery_Pct"], title="Power Draw & Battery Level"), use_container_width=True)
with g2:
    st.plotly_chart(px.line(df, x="Timestamp", y=["CPU_Temp_C", "GPU_Temp_C"], title="Thermals (°C)"), use_container_width=True)

st.divider()
st.subheader("⚠️ High Power Causes Log")
high_power_df = df[df["Power_Status"] == "ABOVE NORMAL"][["Timestamp", "Power_Source", "Power_Draw_W", "CPU_Usage_Pct", "High_Power_Causes"]]
st.dataframe(high_power_df, use_container_width=True)
