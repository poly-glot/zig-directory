import { page } from "fresh";
import { define } from "../../utils.ts";
import { type Category, getClient } from "../../lib/dmoz-client.ts";
import type { User } from "../../lib/kv-users.ts";
import { userIdToSubmitterId } from "../../lib/utils.ts";
import Eyebrow from "../../components/common/Eyebrow/Eyebrow.tsx";
import { EMPTY_STATE, type FormState, type Step } from "./_lib/types.ts";
import { parseFormState, parseStep } from "./_lib/parseForm.ts";
import { validateForStep } from "./_lib/validate.ts";
import Stepper from "../../components/submit/Stepper/Stepper.tsx";
import Step1Form from "../../components/submit/Step1Form/Step1Form.tsx";
import Step2Form from "../../components/submit/Step2Form/Step2Form.tsx";
import Step3Form from "../../components/submit/Step3Form/Step3Form.tsx";
import Step4Review from "../../components/submit/Step4Review/Step4Review.tsx";
import DoneState from "../../components/submit/DoneState/DoneState.tsx";
import styles from "./index.module.css";

interface Data {
  user: User;
  step: Step;
  state: FormState;
  errors: Record<string, string>;
  topCategories: Category[];
  subCategories: Category[];
  referenceId?: number;
}

function loginRedirect(): Response {
  return new Response(null, {
    status: 303,
    headers: { Location: "/auth/login?redirect=/submit" },
  });
}

async function loadTopCategories(
  client: ReturnType<typeof getClient>,
): Promise<Category[]> {
  let categories = await client.listRootCategories(0, 100);
  if (categories.length === 1) {
    try {
      const children = await client.listChildren(categories[0].id, 0, 100);
      if (children.length > 0) categories = children;
    } catch {
      // fall back to single root
    }
  }
  return categories;
}

async function loadSubCategories(
  client: ReturnType<typeof getClient>,
  parentId: number,
): Promise<Category[]> {
  if (parentId <= 0) return [];
  try {
    return await client.listChildren(parentId, 0, 100);
  } catch {
    return [];
  }
}

async function buildData(
  user: User,
  step: Step,
  state: FormState,
  errors: Record<string, string>,
  referenceId?: number,
): Promise<Data> {
  const client = getClient();
  const topCategories = step === "done" ? [] : await loadTopCategories(client);
  const subCategories = step === "done" || state.categoryId <= 0
    ? []
    : await loadSubCategories(client, state.categoryId);
  return {
    user,
    step,
    state,
    errors,
    topCategories,
    subCategories,
    referenceId,
  };
}

async function finalizeSubmission(
  user: User,
  state: FormState,
): Promise<Data> {
  try {
    const client = getClient();
    const targetCategoryId = state.subcategoryId > 0
      ? state.subcategoryId
      : state.categoryId;
    const referenceId = await client.createSubmission(
      targetCategoryId,
      state.url,
      state.title,
      state.description,
      userIdToSubmitterId(user.id),
    );
    return await buildData(user, "done", state, {}, referenceId);
  } catch (e) {
    console.error("Failed to create submission:", e);
    return await buildData(user, 4, state, {
      submit: "Could not save submission. Please try again.",
    });
  }
}

async function handlePost(form: FormData, user: User): Promise<Data> {
  const requestedStep = parseStep(form);
  const state = parseFormState(form);
  const action = form.get("_action")?.toString() ?? "next";

  if (action === "back") {
    const prev = Math.max(1, requestedStep - 1) as 1 | 2 | 3;
    return await buildData(user, prev, state, {});
  }

  const errors = validateForStep(requestedStep, state, form);
  if (Object.keys(errors).length > 0) {
    return await buildData(user, requestedStep, state, errors);
  }

  if (requestedStep === 4) {
    return await finalizeSubmission(user, state);
  }

  const next = (requestedStep + 1) as 2 | 3 | 4;
  return await buildData(user, next, state, {});
}

export const handler = define.handlers<Data>({
  async GET(ctx) {
    const user = ctx.state.user;
    if (!user) return loginRedirect();
    ctx.state.title = "Submit a link";
    return page(await buildData(user, 1, EMPTY_STATE, {}));
  },

  async POST(ctx) {
    const user = ctx.state.user;
    if (!user) return loginRedirect();
    ctx.state.title = "Submit a link";
    const form = await ctx.req.formData();
    return page(await handlePost(form, user));
  },
});

function StepBody({ data }: { data: Data }) {
  if (data.step === "done") return <DoneState referenceId={data.referenceId} />;
  if (data.step === 1) {
    return <Step1Form state={data.state} errors={data.errors} />;
  }
  if (data.step === 2) {
    return <Step2Form state={data.state} errors={data.errors} />;
  }
  if (data.step === 3) {
    return (
      <Step3Form
        state={data.state}
        errors={data.errors}
        topCategories={data.topCategories}
        subCategories={data.subCategories}
      />
    );
  }
  return (
    <Step4Review
      state={data.state}
      errors={data.errors}
      topCategories={data.topCategories}
      subCategories={data.subCategories}
    />
  );
}

export default define.page<typeof handler>(function SubmitPage(props) {
  const { step } = props.data;
  const isDone = step === "done";
  return (
    <>
      <section class="section tight">
        <div class="container">
          <nav class={`crumbs ${styles.crumbs}`}>
            <a href="/">Directory</a>
            <span class="sep">/</span>
            <span class="here">Submit a link</span>
          </nav>
          {!isDone
            ? (
              <div class={styles.heroInner}>
                <Eyebrow muted label="Contribute a site" />
                <h1 class="display mt-16">Submit a link.</h1>
                <p class="lede mt-16">
                  Editors review submissions weekly. Provide accurate
                  information — this is the record we will publish.
                </p>
              </div>
            )
            : null}
        </div>
      </section>

      {!isDone
        ? (
          <div class="container">
            <Stepper step={step} />
          </div>
        )
        : null}

      <section class="section">
        <div class="container">
          <div class={styles.formInner}>
            <StepBody data={props.data} />
          </div>
        </div>
      </section>
    </>
  );
});
