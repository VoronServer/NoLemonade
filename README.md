# No Lemonade

This solution will allow you to utilize both your external AMD GPU together with the integrated graphics on https://lemonade-server.ai/.
As of now, by default, such configuration surprisingly wont work. 

It supports Windows OS only.

Additional benefit is, that it will also allow user to test the latest ROCm builds with Lemonade.

## Disclaimer

NoLemonade is an independent, unofficial project for experimenting with Lemonade SDK and AMD GPU configurations. It is not affiliated with, sponsored by, or endorsed by the Lemonade SDK project or its contributors.
Lemonade SDK and other referenced product names remain the property of their respective owners.

This toolset has been tested only on the author's machine with a limited range of hardware configurations.

Use at your own risk. The author assumes no responsibility or liability for any direct or indirect damage, data loss, system instability, or other consequences arising from the use or misuse of this toolset.

## How to start

Verify your Lemonade version. Bundled scripths are currently targeting only Lemonade v2026.43.3 and may not work with other versions.

1. Use Builder.ps1 to build updated LemonadeServer.exe
2. Use Starter.ps1 to start updated Lemonade.
3. Choose your iGPU and eGPU visibility using Gpu-Visibility.ps1
