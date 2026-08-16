#!/usr/bin/env python3
import asyncio
import json
import os
import threading
import time
import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext
from bleak import BleakScanner, BleakClient

BASE = os.path.expanduser("~/ble-toy-lab")
PROFILE_DIR = os.path.join(BASE, "profiles")
LOG_DIR = os.path.join(BASE, "logs")
os.makedirs(PROFILE_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)

class BLEToyLab:
    def __init__(self, root):
        self.root = root
        self.root.title("BLE Toy Lab")
        self.root.geometry("1050x700")
        self.devices = []
        self.selected = None
        self.client = None
        self.loop = asyncio.new_event_loop()
        threading.Thread(target=self.loop.run_forever, daemon=True).start()
        self.build_gui()

    def build_gui(self):
        top = ttk.Frame(self.root)
        top.pack(fill="x", padx=10, pady=10)
        for label, cmd in [
            ("SCAN", self.start_scan),
            ("INSPECT", self.inspect_selected),
            ("SAVE PROFILE", self.save_profile),
            ("TEST", self.test_selected),
            ("STOP", self.stop_test),
            ("CLEAR", self.clear_output),
        ]:
            ttk.Button(top, text=label, command=cmd).pack(side="left", padx=3)

        main = ttk.PanedWindow(self.root, orient="horizontal")
        main.pack(fill="both", expand=True, padx=10, pady=5)
        left = ttk.Frame(main)
        right = ttk.Frame(main)
        main.add(left, weight=1)
        main.add(right, weight=3)

        ttk.Label(left, text="BLE DEVICES").pack(anchor="w")
        self.device_list = tk.Listbox(left, font=("Courier", 10))
        self.device_list.pack(fill="both", expand=True)
        self.device_list.bind("<<ListboxSelect>>", self.device_selected)

        ttk.Label(right, text="OUTPUT").pack(anchor="w")
        self.output = scrolledtext.ScrolledText(right, font=("Courier", 10))
        self.output.pack(fill="both", expand=True)

        bottom = ttk.Frame(self.root)
        bottom.pack(fill="x", padx=10, pady=5)
        self.status = tk.StringVar(value="Ready")
        ttk.Label(bottom, textvariable=self.status).pack(anchor="w")

    def log(self, text):
        timestamp = time.strftime("%H:%M:%S")
        line = f"[{timestamp}] {text}\n"
        self.root.after(0, lambda: self.output.insert("end", line))
        self.root.after(0, lambda: self.output.see("end"))
        with open(os.path.join(LOG_DIR, "ble_toy_lab.log"), "a", encoding="utf-8") as f:
            f.write(line)

    def clear_output(self):
        self.output.delete("1.0", "end")

    def start_scan(self):
        self.status.set("Scanning...")
        self.device_list.delete(0, "end")
        self.devices = []
        asyncio.run_coroutine_threadsafe(self.scan(), self.loop)

    async def scan(self):
        try:
            discovered = await BleakScanner.discover(timeout=10, return_adv=True)
            for address, item in discovered.items():
                device, adv = item
                record = {
                    "name": device.name or adv.local_name or "Unknown",
                    "address": device.address,
                    "rssi": adv.rssi,
                    "services": adv.service_uuids or [],
                    "manufacturer": {str(k): v.hex() for k, v in adv.manufacturer_data.items()}
                }
                self.devices.append(record)
            self.devices.sort(key=lambda x: x["rssi"], reverse=True)
            self.root.after(0, self.populate_devices)
            self.log(f"Discovered {len(self.devices)} BLE devices")
            self.root.after(0, lambda: self.status.set(f"{len(self.devices)} devices found"))
        except Exception as e:
            self.log(f"Scan error: {e}")
            self.root.after(0, lambda: self.status.set("Scan failed"))

    def populate_devices(self):
        self.device_list.delete(0, "end")
        for i, d in enumerate(self.devices):
            name = d["name"][:24]
            self.device_list.insert("end", f"{i:02d} {name:<24} {d['address']} {d['rssi']:4}")

    def device_selected(self, event=None):
        selection = self.device_list.curselection()
        if not selection:
            return
        self.selected = self.devices[selection[0]]
        self.log(f"Selected: {self.selected['name']} {self.selected['address']}")

    def inspect_selected(self):
        if not self.selected:
            messagebox.showwarning("BLE Toy Lab", "Select a device first.")
            return
        asyncio.run_coroutine_threadsafe(self.inspect(self.selected), self.loop)

    async def inspect(self, device):
        address = device["address"]
        self.log(f"Connecting to {address}")
        try:
            async with BleakClient(address) as client:
                self.log("Connected")
                for service in client.services:
                    self.log(f"SERVICE {service.uuid}")
                    for char in service.characteristics:
                        properties = ", ".join(char.properties)
                        self.log(f"  CHAR {char.uuid} [{properties}]")
                        for descriptor in char.descriptors:
                            self.log(f"    DESC {descriptor.uuid}")
                self.log("GATT inspection complete")
        except Exception as e:
            self.log(f"GATT error: {e}")

    def save_profile(self):
        if not self.selected:
            messagebox.showwarning("BLE Toy Lab", "Select a device first.")
            return
        filename = self.selected["address"].replace(":", "_") + ".json"
        path = os.path.join(PROFILE_DIR, filename)
        with open(path, "w") as f:
            json.dump(self.selected, f, indent=2)
        self.log(f"Profile saved: {path}")

    def test_selected(self):
        if not self.selected:
            messagebox.showwarning("BLE Toy Lab", "Select a device first.")
            return
        if not messagebox.askyesno("Controlled Test", "Test the explicitly selected device?"):
            return
        asyncio.run_coroutine_threadsafe(self.controlled_test(self.selected), self.loop)

    async def controlled_test(self, device):
        address = device["address"]
        interval = 0.5
        self.test_running = True
        try:
            async with BleakClient(address) as client:
                self.client = client
                self.log(f"Connected to selected device {address}")
                writable_chars = [
                    char
                    for service in client.services
                    for char in service.characteristics
                    if "write" in char.properties or "write-without-response" in char.properties
                ]
                self.log(f"Writable characteristics: {len(writable_chars)}")
                if not writable_chars:
                    self.log("No writable characteristics found.")
                    return
                self.log("Controlled test mode: no arbitrary commands sent.")
                for char in writable_chars:
                    if not self.test_running:
                        break
                    self.log(f"Candidate: {char.uuid}")
                    await asyncio.sleep(interval)
                self.log("Test finished.")
        except Exception as e:
            self.log(f"Test error: {e}")
        finally:
            self.client = None
            self.test_running = False

    def stop_test(self):
        self.test_running = False
        self.log("STOP requested")
        if self.client:
            asyncio.run_coroutine_threadsafe(self.client.disconnect(), self.loop)

if __name__ == "__main__":
    root = tk.Tk()
    app = BLEToyLab(root)
    root.mainloop()
