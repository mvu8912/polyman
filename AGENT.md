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
