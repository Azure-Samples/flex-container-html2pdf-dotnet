namespace DeployHelper;

internal static class Program
{
    public static int Main(string[] args)
    {
        try
        {
            DeploymentOperations.Run(args);
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }
}
