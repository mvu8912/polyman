This guide provides the necessary instructions for setting up and running the Perl project environment using Carton.

# AI Agent Instructions: Perl Project Setup & Execution
Follow these steps to configure the environment and execute scripts/tests for this project.
## 1. PrerequisitesBefore installing project dependencies, you must install **Carton** (a Perl module dependency manager).

- **Source:** [Carton v1.0.35](https://cpan.metacpan.org/authors/id/M/MI/MIYAGAWA/Carton-v1.0.35.tar.gz)- **Installation Command:**

2. Dependency Installation
Once Carton is installed, navigate to the project root and run the following command to install all dependencies listed in the cpanfile:

```
carton install
```

3. Running Tests
To execute the test suite, use the prove command through the Carton environment to ensure all local dependencies are included:

```
carton exec prove -r t
```

4. Running Scripts
To run a specific Perl script within the managed environment, use:

```
carton exec perl <script_name>.pl
```

5. For `polymarket` cli you will need to run this command to install it. Some of the function needs that to be run / tested.

```
curl -sSL https://raw.githubusercontent.com/Polymarket/polymarket-cli/main/install.sh | sh
```

6. For Capture::Tiny when testing. You can include that inside t/lib folder

```
carton exec prove -I t/lib -r t
```

7. For any positions related matter. Like list active positions, sell a position in market value or limit price, close a position or redeem a position or sweep / transfer a position. Always refer back to bin/PERFECT-EXAMPLE-HOW-POSTIONS-WORKS.pl to get idea how to do it.

8. This project is base on the compile version of the source code of this cli tool - https://github.com/Polymarket/polymarket-cli
   If I mention about polymarket-cli source code. That is what is all about. And you should have a look into it.
