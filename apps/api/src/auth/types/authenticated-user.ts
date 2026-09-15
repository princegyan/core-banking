export interface AuthenticatedUser {
  id: string;
  email: string;
  tenantId: string;
  branchId: string | null;
}